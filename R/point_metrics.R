#' Point-based metrics
#'
#' Computes a series of user-defined descriptive statistics for a LiDAR dataset for each point. This
#' function is very similar to \link{grid_metrics} but computes metrics \bold{for each point} based on
#' its k-nearest neighbours.
#'
#' It is important to bear in mind that this function is very fast for the feature it provides i.e.
#' mapping a user-defined function at the point level using optimized memory management. However, it
#' is still computationally demanding.\cr\cr
#' To help users to get an idea of how computationally demanding this function is, let's compare it to
#' \link{grid_metrics}. Assuming we want to apply \code{mean(Z)} on a 1 km² tile with 1 point/m²
#' with a resolution of 20 m (400 m² cells), then the function \code{mean} is called roughly 2500
#' times (once  per cell). On the contrary, with \code{point_metrics}, \code{mean} is called 1000000
#' times (once per point). So the function is expected to be more than 400 times slower in this specific
#' case (but it does not provide the same feature).\cr\cr
#' This is why the user-defined function is expected to be well optimized, otherwise it might drastically
#' slow down this already heavy computation. See examples.\cr\cr
#' Last but not least, \code{grid_metrics()} relies on the \code{data.table} package to compute a
#' user-defined function in each pixel. \code{point_metrics()} relies on a similar method but with a
#' major difference: is does not rely on \code{data.table} and thus has not been tested over many years
#' by thousands of people. Please report bugs, if any.
#'
#' @param las An object of class LAS
#' @param func formula. An expression to be applied to each cell (see section "Parameter func").
#' @param k integer. k-nearest neighbours
#' @param xyz logical. Coordinates of each point are returned in addition to each metric. If
#' \code{filter = NULL} coordinates are references to the original coordinates and do not occupy additional
#' memory. If \code{filter != NULL} it obviously takes memory.
#' @param filter formula of logical predicates. Enables the function to run only on points of interest
#' in an optimized way. See also examples.
#'
#' @section Parameter \code{func}:
#' The function to be applied to each cell is a classical function (see examples) that
#' returns a labeled list of metrics. For example, the following function \code{f} is correctly formed.
#' \preformatted{
#' f = function(x) {list(mean = mean(x), max = max(x))}
#' }
#' And could be applied either on the \code{Z} coordinates or on the intensities. These two
#' statements are valid:
#' \preformatted{
#' point_metrics(las, ~f(Z), k = 8)
#' point_metrics(las, ~f(Intensity), k = 5)
#' }
#' Everything that works in \link{grid_metrics} should also work in \code{point_metrics} but might
#' be meaningless. For example, computing the quantile of elevation does not really makes sense here.
#' @examples
#' \dontrun{
#' LASfile <- system.file("extdata", "Topography.laz", package="lidR")
#'
#' # Read only 0.5 points/m^2 for the purposes of this example
#' las = readLAS(LASfile, filter = "-thin_with_grid 2")
#'
#' # Computes the eigenvalues of the covariance matrix of the neighbouring
#' # points and applies a test on these values. This function simulates the
#' # 'shp_plane()' algorithm from 'lasdetectshape()'
#' plane_metrics1 = function(x,y,z, th1 = 25, th2 = 6) {
#'   xyz <- cbind(x,y,z)
#'   cov_m <- cov(xyz)
#'   eigen_m <- eigen(cov_m)$value
#'   is_planar <- eigen_m[2] > (th1*eigen_m[3]) && (th2*eigen_m[2]) > eigen_m[1]
#'   return(list(planar = is_planar))
#' }
#'
#' # Apply a user-defined function
#' M <- point_metrics(las, ~plane_metrics1(X,Y,Z), k = 25)
#' #> Computed in 6.3 seconds
#'
#' # We can verify that it returns the same as 'shp_plane'
#' las <- lasdetectshape(las, shp_plane(k = 25), "planar")
#' #> Computed in 0.1 second
#'
#' all.equal(M$planar, las$planar)
#'
#' # At this stage we can be clever and find that the bottleneck is
#' # the eigenvalue computation. Let's write a C++ version of it with
#' # Rcpp and RcppArmadillo
#' Rcpp::sourceCpp(code = "
#' #include <RcppArmadillo.h>
#' // [[Rcpp::depends(RcppArmadillo)]]
#'
#' // [[Rcpp::export]]
#' SEXP eigen_values(arma::mat A) {
#' arma::mat coeff;
#' arma::mat score;
#' arma::vec latent;
#' arma::princomp(coeff, score, latent, A);
#' return(Rcpp::wrap(latent));
#' }")
#'
#' plane_metrics2 = function(x,y,z, th1 = 25, th2 = 6) {
#'   xyz <- cbind(x,y,z)
#'   eigen_m <- eigen_values(xyz)
#'   is_planar <- eigen_m[2] > (th1*eigen_m[3]) && (th2*eigen_m[2]) > eigen_m[1]
#'   return(list(planar = is_planar))
#' }
#'
#' M <- point_metrics(las, ~plane_metrics2(X,Y,Z), k = 25)
#' #> Computed in 0.5 seconds
#'
#' all.equal(M$planar, las$planar)
#' # Here we can see that the optimized version is way better but is still 5 times slower
#' # because of the overhead of calling R functions and switching back and forth from R to C++.
#'
#'
#' # Use the filter argument to process only first returns
#' M1 <- point_metrics(las, ~plane_metrics2(X,Y,Z), k = 25, filter = ~ReturnNumber == 1)
#' dim(M1) # 13894 instead of 17182 previously.
#'
#' # is a memory-optimized equivalent to:
#' first = lasfilterfirst(las)
#' M2 <- point_metrics(first, ~plane_metrics2(X,Y,Z), k = 25)
#' all.equal(M1, M2)
#' }
#' @export
#' @family metrics
point_metrics <- function(las, func, k = 8L, xyz = TRUE, filter = NULL) {
  UseMethod("point_metrics", las)
}

#' @export
point_metrics.LAS <- function(las, func, k = 8L, xyz = TRUE, filter = NULL) {
  # Defensive programming
  assert_is_a_number(k)
  assert_is_a_bool(xyz)
  k <- as.integer(k)
  stopifnot(k > 1)
  formula <- tryCatch(lazyeval::is_formula(func), error = function(e) FALSE)
  if (!formula) func <- lazyeval::f_capture(func)

  # Preparation of the objects
  func <- lazyeval::f_interp(func)
  call <- lazyeval::as_call(func)
  data <- las@data

  # Memory allocation for the query. This memory will be recycled in each iteration
  query <- data[1:k]

  # Creation of a call environment
  env <- new.env(parent = parent.frame())
  for (n in names(query)) assign(n, query[[n]], envir = env)

  filter <- parse_filter(las, filter)
  output <- C_point_metrics(las, k, query, call, env, filter)

  if (length(output[[1]]) == 1) {
    name <- names(output[[1]])
    output <- data.table::data.table(unlist(output))
    if (!is.null(name)) data.table::setnames(output, name)
  }
  else {
    output <- data.table::rbindlist(output)
  }

  if (xyz) {
    xyz <- coordinates3D(las)
    data.table::setDT(xyz)
    if (length(filter) > 1 && !all(filter)) xyz <- xyz[filter]
    coln <- names(output)
    coln <- c("X", "Y", "Z", coln)
    output[["X"]] <- xyz$X
    output[["Y"]] <- xyz$Y
    output[["Z"]] <- xyz$Z
    data.table::setcolorder(output, coln)
    output[]
  }

  return(output)
}
