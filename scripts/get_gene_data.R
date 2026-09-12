suppressMessages(library(dplyr, quietly = TRUE))
suppressMessages(library(SummarizedExperiment, quietly = TRUE))
suppressMessages(library(MDALL, quietly = TRUE))
suppressMessages(library(jsonlite, quietly = TRUE))

args <- commandArgs(trailingOnly = TRUE)
indir <- normalizePath(args[1], mustWork = TRUE)
gene_name <- toupper(args[2])
app_root <- dirname(dirname(indir))

setwd(indir)

# Load the pre-computed VST data from the main pipeline run
rds_file <- list.files(pattern="^vst_data_.*\\.rds$")[1]
if (is.na(rds_file)) stop("Pipeline data not found. Please ensure a run has completed.")

df_vst_i <- readRDS(rds_file)
sample_id <- colnames(df_vst_i)[2]

extract_ref_se <- function(x) {
  if (inherits(x, "SummarizedExperiment")) return(x)
  if (!is.list(x)) return(NULL)

  preferred_names <- c("se", "obj", "object", "sce", "reference")
  for (nm in preferred_names) {
    if (!is.null(x[[nm]]) && inherits(x[[nm]], "SummarizedExperiment")) {
      return(x[[nm]])
    }
  }

  for (item in x) {
    if (inherits(item, "SummarizedExperiment")) return(item)
  }

  NULL
}

extract_ref_matrix <- function(x) {
  se_obj <- extract_ref_se(x)
  if (!is.null(se_obj)) {
    assay_names <- tryCatch(SummarizedExperiment::assayNames(se_obj), error = function(e) character(0))
    if ("vst" %in% assay_names) return(SummarizedExperiment::assay(se_obj, "vst"))
    return(SummarizedExperiment::assay(se_obj, 1))
  }

  if (is.list(x)) {
    if (!is.null(x$vst)) return(as.matrix(x$vst))
    if (!is.null(x$assays$vst)) return(as.matrix(x$assays$vst))
    if (!is.null(x$assays[[1]])) return(as.matrix(x$assays[[1]]))
  }

  stop("Unable to extract reference VST matrix from MDALL object.")
}

extract_ref_subtypes <- function(x, n_cols) {
  se_obj <- extract_ref_se(x)
  if (!is.null(se_obj)) {
    meta <- as.data.frame(SummarizedExperiment::colData(se_obj))
    subtype_col <- c("subtype", "Subtype", "diag", "Diagnosis")[c("subtype", "Subtype", "diag", "Diagnosis") %in% colnames(meta)][1]
    if (!is.na(subtype_col)) return(as.character(meta[[subtype_col]]))
  }

  if (is.list(x)) {
    meta_candidates <- list(x$colData, x$meta, x$metadata, x$pheno)
    for (meta in meta_candidates) {
      if (is.data.frame(meta)) {
        subtype_col <- c("subtype", "Subtype", "diag", "Diagnosis")[c("subtype", "Subtype", "diag", "Diagnosis") %in% colnames(meta)][1]
        if (!is.na(subtype_col)) return(as.character(meta[[subtype_col]]))
      }
    }
  }

  rep("Unknown", n_cols)
}

ref_matrix <- extract_ref_matrix(obj_1821)

resolve_feature_id <- function(gene_name, indir) {
  ref_ids <- rownames(ref_matrix)
  if (gene_name %in% ref_ids) return(gene_name)
  if (any(toupper(ref_ids) == gene_name)) return(ref_ids[which(toupper(ref_ids) == gene_name)[1]])

  gtf_candidates <- c(
    file.path(indir, "gtf1.txt"),
    Sys.getenv("GTF_FILE", unset = ""),
    file.path(app_root, "resources", "gtf1.txt")
  )
  gtf_candidates <- gtf_candidates[nzchar(gtf_candidates)]

  for (gtf_path in unique(gtf_candidates)) {
    if (!file.exists(gtf_path)) next
    gtf <- tryCatch(read.table(gtf_path, header = TRUE, sep = ",", stringsAsFactors = FALSE), error = function(e) NULL)
    if (is.null(gtf) || !all(c("gene_id", "gene_name") %in% colnames(gtf))) next

    hit <- gtf[toupper(gtf$gene_name) == gene_name, , drop = FALSE]
    if (nrow(hit) == 0) next

    candidate_ids <- sub("\\..*$", "", hit$gene_id)
    ref_ids_clean <- sub("\\..*$", "", ref_ids)
    idx <- match(candidate_ids, ref_ids_clean)
    idx <- idx[!is.na(idx)]
    if (length(idx) > 0) return(ref_ids[idx[1]])
  }

  NA_character_
}

feature_id <- resolve_feature_id(gene_name, indir)
if (is.na(feature_id)) {
  stop(paste("Gene", gene_name, "not found in the reference cohort."))
}

# Extract sample expression
sample_expression_row <- df_vst_i %>% dplyr::filter(feature == feature_id)
if (nrow(sample_expression_row) == 0) {
  stop(paste("Gene", gene_name, "not found in the query sample."))
}
sample_expression <- as.numeric(sample_expression_row[[sample_id]])

# Get reference expression and subtypes
ref_expression <- as.numeric(ref_matrix[feature_id, ])
ref_subtypes <- extract_ref_subtypes(obj_1821, ncol(ref_matrix))

# Create a list object to export as JSON
output_list <- list(
  gene = gene_name,
  sampleId = sample_id,
  sampleValue = sample_expression,
  reference = data.frame(
    expression = ref_expression,
    subtype = ref_subtypes
  )
)

# Write to a JSON file so Node.js can easily read it
write(toJSON(output_list, auto_unbox = TRUE), "search_results.json")
