.improvedCV2 <- function(x, is.spike, sf.cell=NULL, sf.spike=NULL, log.prior=NULL, 
                         df=4, robust=FALSE, use.spikes=FALSE)
# Fits a spline to the log-CV2 values and computes a p-value for its deviation.
#
# written by Aaron Lun
# created 9 February 2017
# last modified 23 November 2017
{
    # Figuring out what rows to fit to.
    all.genes <- seq_len(nrow(x))
    if (any(is.na(is.spike))) { 
        use.spikes <- TRUE
        is.spike <- all.genes
    } else {
        is.spike <- .subset_to_index(is.spike, x, byrow=TRUE)
    }

    # Extracting statistics.
    if (is.null(log.prior)) {
        is.cell <- seq_len(nrow(x))[-is.spike]
        if (is.null(sf.cell)) sf.cell <- 1
        sf.cell <- rep(sf.cell, length.out=ncol(x))
        if (is.null(sf.spike)) sf.spike <- 1
        sf.spike <- rep(sf.spike, length.out=ncol(x))

        spike.stats <- .Call(cxx_compute_CV2, x, is.spike-1L, sf.spike, NULL)
        cell.stats <- .Call(cxx_compute_CV2, x, is.cell-1L, sf.cell, NULL)

        means <- vars <- numeric(nrow(x))
        means[is.cell] <- cell.stats[[1]]
        vars[is.cell] <- cell.stats[[2]]
        means[is.spike] <- spike.stats[[1]]
        vars[is.spike] <- spike.stats[[2]]
    } else {
        log.prior <- as.numeric(log.prior)
        all.stats <- .Call(cxx_compute_CV2, x, all.genes-1L, NULL, log.prior)
        means <- all.stats[[1]]
        vars <- all.stats[[2]]
    }

    cv2 <- vars/means^2
    log.means <- log(means)
    log.cv2 <- log(cv2)

    # Pulling out spike-in values.
    ok.means <- is.finite(log.means)
    to.use <- ok.means & is.finite(log.cv2)
    to.use[-is.spike] <- FALSE

    # Ignoring maxed CV2 values due to an outlier (caps at the number of cells).
    ignored <- cv2 >= ncol(x) - 1e-8
    to.use[ignored] <- FALSE
    use.log.means <- log.means[to.use]
    use.log.cv2 <- log.cv2[to.use]

    # Fit a spline to the log-variances.
    # We need to use predict() to get fitted values, as fitted() can be NA for repeated values.
    if (robust) {
        fit <- aroma.light::robustSmoothSpline(use.log.means, use.log.cv2, df=df)
        fitted.val <- predict(fit, use.log.means)$y
        tech.var <- sum((fitted.val - use.log.cv2)^2)/(length(use.log.cv2)-fit$df)
        tech.sd <- sqrt(tech.var)
    } else {
        fit <- smooth.spline(use.log.means, use.log.cv2, df=df)
        fitted.val <- predict(fit, use.log.means)$y
        tech.sd <- median(abs(fitted.val - use.log.cv2)) * 1.4826
    }
    tech.log.cv2 <- predict(fit, log.means[ok.means])$y

    # Compute p-values.
    p <- rep(1, length(ok.means))
    p[ok.means] <- pnorm(log.cv2[ok.means], mean=tech.log.cv2, sd=tech.sd, lower.tail=FALSE)
    if (!use.spikes) {
        p[is.spike] <- NA
    }

    tech.cv2 <- rep(NA_real_, length(ok.means))    
    tech.cv2[ok.means] <- exp(tech.log.cv2 + tech.sd^2/2) # correcting for variance
    return(data.frame(mean=means, var=vars, cv2=cv2, trend=tech.cv2, 
                      p.value=p, FDR=p.adjust(p, method="BH"), row.names=rownames(x)))
}

setGeneric("improvedCV2", function(x, ...) standardGeneric("improvedCV2"))

setMethod("improvedCV2", "ANY", .improvedCV2)

setMethod("improvedCV2", "SingleCellExperiment", 
          function(x, spike.type=NULL, ..., assay.type="logcounts", logged=NULL, normalized=NULL) {

    log.prior <- NULL
    if (!is.null(logged)) {
        if (logged) {
            log.prior <- .get_log_offset(x)
        }
    } else {
        if (assay.type=="logcounts") {
            log.prior <- .get_log_offset(x)
        } else if (assay.type!="counts" && assay.type!="normcounts") {
            stop("cannot determine if values are logged")
        }
    }

    if (is.null(normalized)) {
        normalized <- FALSE
        if (assay.type=="logcounts" || assay.type=="normcounts") {
            normalized <- TRUE
        } else if (assay.type!="counts") {
            stop("cannot determine if values are normalized")
        }
    }
    
    if (normalized) {
        prep <- list(is.spike=isSpike(x, type=spike.type))
    } else {
        prep <- .prepare_cv2_data(x, spike.type=spike.type)
    }

    .improvedCV2(assay(x, i=assay.type), is.spike=prep$is.spike, 
                 sf.cell=prep$sf.cell, sf.spike=prep$sf.spike, log.prior=log.prior, ...)          
})

