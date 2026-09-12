suppressMessages(library(dplyr, quietly = TRUE))
suppressMessages(library(stringr, quietly = TRUE))
suppressMessages(library(tidyverse, quietly = TRUE))
suppressMessages(library(ALLCatchR, quietly = TRUE))
suppressMessages(library(optparse, quietly = TRUE))
suppressMessages(library(getopt, quietly = TRUE))
suppressMessages(library(progress, quietly = TRUE))
library(Rphenograph)
library(SummarizedExperiment)
library(MDALL)
options(scipen = 999)

option_list = list(make_option(c("-i", "--indir"), type = "character",
                               help = "Path to input directory where quant.sf files exist",
                               metavar = "path", action = "store"),
                   make_option(c("-g", "--gtf"), type = "character",
                               help = "Path to gtf file", default="/Users/vyellapantula/local/resources/gtf1.txt",
                               metavar = "path", action = "store"),
                   make_option(c("-o","--output"), type = "character",
                               help = "Output suffix",
                               metavar = "path", action="store"));

opt_parser = OptionParser(option_list=option_list);
opt = parse_args(opt_parser);

indir=opt$indir
gtf_file=opt$gtf
out_file=opt$output

# Set the working directory to the dynamic run folder created by Node.js
setwd(indir)

cat("Creating count matrix .....\n")
i=list.files(pattern="*.sf$")[1]

df = read_tsv(i,show_col_types = FALSE)
for(i in list.files(pattern="*.sf$")) {
  print(i)
  df1 = read_tsv(i,show_col_types = FALSE) %>% dplyr::select(Name,NumReads) %>% 
    dplyr::mutate(NumReads=round(NumReads))
  colnames(df1)=c("ren",gsub("_RNASEQ_Clinical1.0_dragen.quant.genes.sf","",basename(i)))
  df = left_join(df,df1,by=c("Name"="ren"))
}

gtf = read.table(gtf_file,header=T,sep=",")

df = df %>% dplyr::left_join(gtf, by=c("Name"="gene_id")) %>% 
  dplyr::select(-Name,-Length,-EffectiveLength,-TPM,-NumReads)

c1 = df
c1=c1[!duplicated(c1$gene_name),]
c1=c1[!is.na(c1$gene_name),]
c1=c1[c1$gene_name!="",]
# gene_name first, then every sample column (previously grep("M") on column names,
# which silently dropped any sample whose file name had no capital M).
c2=c1[,c("gene_name", setdiff(colnames(c1), "gene_name"))]
c3=as.matrix(c2 %>% dplyr::select(-gene_name))
rownames(c3)=c2$gene_name
c3=as.data.frame(t((c3)))

# Save count matrices into the run folder
write.table(c3,"counts.csv",quote=FALSE,sep=",")
write_csv(c3,"counts.v2.csv",progress = show_progress())

###### ALLSORTS ####
cat("Running ALLSorts .....\n")
system("mkdir -p allsorts_results")

# Force the shell to load conda, activate the environment, and run ALLSorts
#allsorts_cmd <- "source /Users/vyellapantula/miniconda3/etc/profile.d/conda.sh && conda activate allsorts && ALLSorts -samples counts.csv -destination ./allsorts_results/"
allsorts_bin <- Sys.getenv("ALLSORTS_BIN", unset = "/opt/anaconda3/envs/allsorts/bin/ALLSorts")
allsorts_cmd <- sprintf("%s -samples counts.csv -destination ./allsorts_results/", allsorts_bin)

cat(sprintf("Executing: %s\n", allsorts_cmd))
exit_status <- system(allsorts_cmd)

# Stop the script immediately if ALLSorts fails so we know exactly where the issue is
if (exit_status != 0) {
  stop("ALLSorts failed to run. Please check the terminal output for Python/Conda errors.")
}

###### ALLCatchR ####
cat("Running ALLCatchR .....\n")
catch=cbind(c1[,"gene_name"],c1[,c(1:(dim(c1)[2]-1))])
colnames(catch)[1]="symbol"

# Save catch.tsv to the run folder
write.table(catch, "catch.tsv", quote=FALSE, sep="\t", col.names=T, row.names=F, append=F)
# Run ALLCatchR using the relative file
my_predictions <- allcatch(Counts.file = "catch.tsv", ID_class = "symbol", sep = "\t")
# Save the predictions so script 2 can find them
write_tsv(my_predictions, "predictions.tsv")


#########################################################################
#####################       MDALL #######################################
#########################################################################

cat("Creating input file for MDALL .....\n")

i=list.files(pattern="*.sf$")[1]

df = read_tsv(i,show_col_types = FALSE) %>% dplyr::select(Name) %>%
  dplyr::mutate(Name=stringr::str_extract(Name,"ENSG0[0-9]+")) %>% distinct()

for(i in list.files(pattern="*.sf$")) {
  print(i)
  df1 = read_tsv(i,show_col_types = FALSE) %>% dplyr::select(Name,NumReads) %>% 
    dplyr::mutate(NumReads=round(NumReads), Name=stringr::str_extract(Name,"ENSG0[0-9]+")) %>%
    dplyr::select(Name,NumReads) %>% distinct(Name, .keep_all = TRUE)
  sample=gsub("_RNASEQ_Clinical1.0_dragen.quant.genes.sf","",basename(i))
  colnames(df1)=c("ren",gsub("_RNASEQ_Clinical1.0_dragen.quant.genes.sf","",basename(i)))
  df = left_join(df,df1,by=c("Name"="ren"))
}

write_tsv(df,sprintf("MDall_%s.txt",out_file),col_names = T)

###### Run MDALL ######
mdall_input = sprintf("MDall_%s.txt",out_file)
count_matrix=vroom::vroom(mdall_input)
colnames(count_matrix)[1] = "feature"

get_GEP_pred=function(count_matrix,
                      featureN_PG=c(100,200,300,400,500,600,700,800,900,1000,1058)){
  df_vsts=get_vst_values(obj_in = obj_234_HTSeq,df_count = count_matrix)
  
  df_listing=data.frame(id=colnames(df_vsts)[2:ncol(df_vsts)],stringsAsFactors = F) %>% 
    mutate(obs=1:n())
  
  df_out_GEP=bind_rows(lapply(df_listing$obs,function(i){
    sample_id=df_listing$id[i]
    cat(paste0("Prediction for ",sample_id," ...\n"))
    
    #imputation
    df_vst_i=f_imputation(obj_ref = obj_234_HTSeq,df_in = df_vsts[c("feature",sample_id)])
    saveRDS(df_vst_i, sprintf("vst_data_%s.rds", sample_id))
    
    #get obj
    obj_=obj_merge(obj_in = obj_1821,df_in = df_vst_i,assay_name_in = "vst")
    
    #phenograph
    cat("Running phenograph...")
    df_out_phenograph=get_PhenoGraphPreds(obj_in = obj_,feature_panel = "keyFeatures",SampleLevel = sample_id,
                                          neighbor_k = 10,
                                          variable_n_list = featureN_PG
    )
  # Save UMAP data for the interactive web plot ─────────
    suppressMessages(library(jsonlite, quietly = TRUE))
    
    # Build a real 2D embedding for the interactive plot. The current MDALL
    # package returns only PhenoGraph summary labels, not UMAP coordinates.
    variable_genes_in = obj_$keyFeatures[1:min(1058, length(obj_$keyFeatures))]
    embedding_input = t(assays(obj_$SE[variable_genes_in, ])[["vst"]])

    if (nrow(embedding_input) >= 2 && ncol(embedding_input) >= 2) {
      if (requireNamespace("uwot", quietly = TRUE)) {
        set.seed(10)
        neighbor_n = max(2, min(15, nrow(embedding_input) - 1))
        coords = uwot::umap(
          embedding_input,
          n_components = 2,
          n_neighbors = neighbor_n,
          metric = "euclidean",
          verbose = FALSE
        )
        umap_df = data.frame(
          sample_id = rownames(embedding_input),
          uMAP_1 = coords[, 1],
          uMAP_2 = coords[, 2],
          subtype = as.character(obj_$SE$diag),
          stringsAsFactors = FALSE
        )
      } else {
        pca = prcomp(embedding_input, center = TRUE, scale. = TRUE)
        umap_df = data.frame(
          sample_id = rownames(embedding_input),
          uMAP_1 = pca$x[, 1],
          uMAP_2 = pca$x[, min(2, ncol(pca$x))],
          subtype = as.character(obj_$SE$diag),
          stringsAsFactors = FALSE
        )
      }
      umap_df$is_query = umap_df$sample_id == sample_id
      write_json(umap_df, paste0("umap_data_", sample_id, ".json"))
    }

    cat("Running SVM...\n")
    df_out_svm=get_SVMPreds(models_svm,df_in = df_vst_i,id = sample_id)
    df_feateure_exp=get_geneExpression(df_vst = df_vsts[c("feature",sample_id)],genes = c("CDX2","CRLF2","NUTM1"))
    
    data.frame(
      sample_id=sample_id,
      CDX2=df_feateure_exp$Expression[df_feateure_exp$Gene=="CDX2"],
      CRLF2=df_feateure_exp$Expression[df_feateure_exp$Gene=="CRLF2"],
      NUTM1=df_feateure_exp$Expression[df_feateure_exp$Gene=="NUTM1"],
      phenoGraph_pred=get_pred_result(df_out_phenograph),
      phenoGraph_predScore=get_pred_score(df_out_phenograph),
      phenoGraph_predLabel=get_pred_label(df_out_phenograph),
      
      svm_pred=get_pred_result(df_out_svm),
      svm_predScore=get_pred_score(df_out_svm),
      svm_predLabel=get_pred_label(df_out_svm),
      
      stringsAsFactors = F
    )
  }))
}

df_out_gep=get_GEP_pred(count_matrix = count_matrix)

write_tsv(df_out_gep,sprintf("MDall_output_%s.txt",out_file),col_names = T)
