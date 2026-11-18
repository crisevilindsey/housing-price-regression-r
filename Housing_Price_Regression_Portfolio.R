# Housing Price Regression Analysis | Portfolio Edition
# Author: Criselvi Lindsey
# Source coursework: Homework8_Criselvi_Lindsey.R and Assignment_8&9_Criselvi_Lindsey.R
# Purpose: Reproducible data preparation, regression modeling, and diagnostics.
# This is a corrected adaptation; original coursework files are unchanged.
#
# Setup: install.packages("readxl")
# Put week-6-housing.xlsx in the same working directory as this script,
# or set input_file to its full path below.
# Run from that directory using source("Housing_Price_Regression_Portfolio.R").

input_file <- "week-6-housing.xlsx"
output_dir <- "outputs"
set.seed(680)

if (!requireNamespace("readxl", quietly = TRUE)) {
  stop("Package 'readxl' is required. Run install.packages('readxl').")
}
if (!file.exists(input_file)) {
  stop("Input file not found: ", input_file,
       ". Set your working directory or edit input_file.")
}
dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)

# 1. Import and validate schema
housing <- as.data.frame(readxl::read_excel(input_file, sheet = 1))
names(housing) <- trimws(names(housing))
names(housing)[names(housing) == "Sale Price"] <- "sale_price"
names(housing)[names(housing) == "Sale Date"] <- "sale_date"
required <- c("sale_price", "sq_ft_lot", "square_feet_total_living",
              "bedrooms", "bath_full_count", "year_built")
missing_columns <- setdiff(required, names(housing))
if (length(missing_columns)) {
  stop("Required columns missing: ", paste(missing_columns, collapse = ", "))
}
original_n <- nrow(housing)

# 2. Clean data, retaining source fields for traceability
housing <- unique(housing)
for (column in names(housing)) {
  if (is.character(housing[[column]])) housing[[column]] <- trimws(housing[[column]])
}
if ("ctyname" %in% names(housing) && "postalctyn" %in% names(housing)) {
  blank_city <- is.na(housing$ctyname) | housing$ctyname == ""
  housing$ctyname[blank_city] <- housing$postalctyn[blank_city]
}
if ("year_renovated" %in% names(housing)) {
  housing$year_renovated <- suppressWarnings(as.numeric(housing$year_renovated))
  housing$year_built <- suppressWarnings(as.numeric(housing$year_built))
  # Preserve missing renovation years; a zero is treated as no recorded renovation.
  zero_renovation <- !is.na(housing$year_renovated) & housing$year_renovated == 0
  housing$year_renovated[zero_renovation] <- housing$year_built[zero_renovation]
}
if ("sale_date" %in% names(housing)) {
  if (inherits(housing$sale_date, "POSIXt")) {
    housing$sale_date <- as.Date(housing$sale_date)
  } else if (!inherits(housing$sale_date, "Date")) {
    if (is.numeric(housing$sale_date)) {
      housing$sale_date <- as.Date(housing$sale_date, origin = "1899-12-30")
    } else {
      housing$sale_date <- as.Date(housing$sale_date, tryFormats = c("%m/%d/%Y", "%Y-%m-%d"))
    }
  }
}
for (column in required) {
  housing[[column]] <- suppressWarnings(as.numeric(housing[[column]]))
}
# Preserve factor preparation from Assignment 8&9 when columns exist.
categorical <- intersect(c("sale_reason", "sale_instrument", "sitetype",
                           "building_grade", "current_zoning", "prop_type",
                           "present_use"), names(housing))
for (column in categorical) housing[[column]] <- as.factor(housing[[column]])

# Only complete cases for the explicitly modeled variables are used.
model_data <- housing[stats::complete.cases(housing[, required, drop = FALSE]), , drop = FALSE]
model_data <- model_data[model_data$sale_price > 0 &
                           model_data$sq_ft_lot >= 0 &
                           model_data$square_feet_total_living > 0 &
                           model_data$bedrooms >= 0 &
                           model_data$bath_full_count >= 0 &
                           model_data$year_built > 0, , drop = FALSE]
if (nrow(model_data) < 30L) stop("Too few usable rows after cleaning.")

# 3. Split before fitting or estimating outlier thresholds (avoids test leakage).
train_ids <- sample.int(nrow(model_data), size = floor(0.8 * nrow(model_data)))
train <- model_data[train_ids, , drop = FALSE]
test <- model_data[-train_ids, , drop = FALSE]

# Estimate sale-price IQR limits on training data only.
q <- stats::quantile(train$sale_price, probs = c(0.25, 0.75), na.rm = TRUE)
iqr <- unname(q[2] - q[1])
lower <- unname(q[1] - 1.5 * iqr)
upper <- unname(q[2] + 1.5 * iqr)
train_filtered <- train[train$sale_price >= lower & train$sale_price <= upper, , drop = FALSE]
if (nrow(train_filtered) < 20L) stop("Too few training rows after IQR filtering.")
# Keep the test set intact to measure performance on the original held-out distribution.

# 4. Compare a simple baseline with an interpretable multiple regression.
simple_model <- stats::lm(sale_price ~ sq_ft_lot, data = train_filtered)
multiple_model <- stats::lm(
  sale_price ~ sq_ft_lot + square_feet_total_living + bedrooms +
    bath_full_count + year_built,
  data = train_filtered
)

# 5. Evaluate on the same untouched holdout sample.
score_model <- function(model, new_data, model_name) {
  prediction <- as.numeric(stats::predict(model, newdata = new_data))
  actual <- new_data$sale_price
  valid <- is.finite(prediction) & is.finite(actual)
  if (!any(valid)) stop("No valid predictions for ", model_name)
  prediction <- prediction[valid]
  actual <- actual[valid]
  mse <- mean((actual - prediction)^2)
  rmse <- sqrt(mse)
  mae <- mean(abs(actual - prediction))
  denominator <- sum((actual - mean(actual))^2)
  r_squared <- if (denominator > 0) 1 - sum((actual - prediction)^2) / denominator else NA_real_
  data.frame(model = model_name, test_rows = length(actual),
             RMSE = rmse, MAE = mae, R_squared = r_squared)
}
metrics <- rbind(score_model(simple_model, test, "Simple linear regression"),
                 score_model(multiple_model, test, "Multiple linear regression"))
write.csv(metrics, file.path(output_dir, "holdout_model_metrics.csv"), row.names = FALSE)

predictions <- data.frame(
  actual_sale_price = test$sale_price,
  simple_prediction = as.numeric(predict(simple_model, newdata = test)),
  multiple_prediction = as.numeric(predict(multiple_model, newdata = test))
)
write.csv(predictions, file.path(output_dir, "holdout_predictions.csv"), row.names = FALSE)

# 6. Save regression diagnostics based on the training fit.
png(file.path(output_dir, "multiple_model_residuals.png"), width = 1100, height = 750)
plot(fitted(multiple_model), resid(multiple_model), pch = 16, cex = 0.5,
     xlab = "Fitted sale price", ylab = "Residual",
     main = "Multiple Regression: Residuals vs Fitted (Training Data)")
abline(h = 0, col = "red", lty = 2)
dev.off()

png(file.path(output_dir, "multiple_model_qq.png"), width = 1100, height = 750)
qqnorm(resid(multiple_model), main = "Multiple Regression: Q-Q Plot (Training Data)")
qqline(resid(multiple_model), col = "red", lty = 2)
dev.off()

png(file.path(output_dir, "holdout_actual_vs_predicted.png"), width = 1100, height = 750)
plot(predictions$actual_sale_price, predictions$multiple_prediction,
     pch = 16, cex = 0.5, xlab = "Actual sale price",
     ylab = "Predicted sale price",
     main = "Multiple Regression: Held-Out Actual vs Predicted")
abline(a = 0, b = 1, col = "red", lty = 2)
dev.off()

# Optional Breusch-Pagan test: install.packages("lmtest") if desired.
if (requireNamespace("lmtest", quietly = TRUE)) {
  bp <- lmtest::bptest(multiple_model)
  capture.output(bp, file = file.path(output_dir, "breusch_pagan_test.txt"))
}

# Save model summaries and cleaning audit (no unsupported hard-coded findings).
capture.output(summary(simple_model), summary(multiple_model),
               file = file.path(output_dir, "model_summaries.txt"))
audit <- data.frame(
  measure = c("Source rows", "After duplicate removal", "Usable modeling rows",
              "Training rows before outlier filtering", "Training rows after IQR filtering",
              "Holdout rows", "Training IQR lower limit", "Training IQR upper limit"),
  value = c(original_n, nrow(housing), nrow(model_data), nrow(train),
            nrow(train_filtered), nrow(test), lower, upper)
)
write.csv(audit, file.path(output_dir, "data_preparation_audit.csv"), row.names = FALSE)

cat("Housing regression analysis completed.\n")
cat("Results saved in: ", normalizePath(output_dir), "\n", sep = "")
print(audit, row.names = FALSE)
print(metrics, row.names = FALSE)
cat("Note: Holdout metrics are newly computed and are not the same as the original coursework's in-sample results.\n")
