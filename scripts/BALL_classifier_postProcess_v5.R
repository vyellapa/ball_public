# B-ALL merge script takes as input AllSorts, AllCatcher and MD-ALL outputs and generates final classification and confidence
#title: "BALL_classifier_postProcess"
#author: "Venkata Yellapantula"
#date modified: "2024-08-09"

### Example usage for validation samples
#Rscript /Users/vyellapantula/Desktop/projects/RNASeq/validation_auto/data/BALL_classifier_postProcess_v3.R \
#-m /Users/vyellapantula/Desktop/projects/RNASeq/validation_auto/data/sf_0420/MDall_output_val_auto.txt \
#-c /Users/vyellapantula/Desktop/projects/RNASeq/validation_auto/data/sf_0420/predictions.tsv \
#-s /Users/vyellapantula/Desktop/projects/RNASeq/validation_auto/data/sf_0420/allsorts_results/probabilities.csv -l 0.4 -u 0.8



suppressMessages(library(dplyr, quietly = TRUE))
suppressMessages(library(stringr, quietly = TRUE))
suppressMessages(library(tidyverse, quietly = TRUE))
suppressMessages(library(optparse, quietly = TRUE))
suppressMessages(library(getopt, quietly = TRUE))
library(progress)
options(scipen = 999)


#mdall="/Users/vyellapantula/Desktop/projects/RNASeq/validation/data/sf/MDALL_validation59_countMatrix_sum.tsv"
mdall = "/Users/vyellapantula/Desktop/projects/RNASeq/validation_auto/data/sf_0420/MDall_output_val_auto.txt"
allCatcher="/Users/vyellapantula/Desktop/projects/RNASeq/validation_auto/data/sf_0420/predictions.tsv"
allSorts="/Users/vyellapantula/Desktop/projects/RNASeq/validation_auto/data/sf_0420/allsorts_results/probabilities.csv"
hi_conf=0.8
low_conf=0.4

option_list = list(make_option(c("-s", "--allSorts"), type = "character",
                               help = "Path to ALL-SORTS output",
                               metavar = "path", action = "store"),
                   make_option(c("-c", "--allCatcher"), type = "character",
                               help = "Path to ALL-CATCHER output",
                               metavar = "path", action = "store"),
                   make_option(c("-m","--mdAll"), type = "character",
                               help = "Path to MD-ALL output",
                               metavar = "path", action="store"),
                   make_option(c("-u","--hiConf"), type = "double",
                               help = "High confidence threshold [0.8]",default = 0.8,
                               metavar = "double", action="store"),
                   make_option(c("-l","--lowConf"), type = "double",
                               help = "Low confidence threshold [0.4]",default = 0.4,
                               metavar = "double", action="store"));




opt_parser = OptionParser(option_list=option_list);
opt = parse_args(opt_parser);


allSorts=opt$allSorts
allCatcher=opt$allCatcher
mdall=opt$mdAll
hi_conf=as.numeric(opt$hiConf)
low_conf=as.numeric(opt$lowConf)

if( file.access(allSorts) == -1) {
  stop(sprintf("Specified file ( %s ) does not exist", allSorts))
} 

if( file.access(allCatcher) == -1) {
  stop(sprintf("Specified file ( %s ) does not exist", allCatcher))
} 

if( file.access(mdall) == -1) {
  stop(sprintf("Specified file ( %s ) does not exist", mdall))
} 

cat(sprintf("Running post-processing script with low and high-confidence thresholds of %s and %s ...\n",low_conf, hi_conf))

md=read_tsv(mdall,show_col_types = FALSE)
ac=read_tsv(allCatcher,show_col_types = FALSE)
as=read_csv(allSorts,show_col_types = FALSE)


##############################################################################################################
######################                  Preprocess Outputs                              ######################
##############################################################################################################

### Pre-process MD-ALL file ##########
md = md %>% dplyr::select(sample_id,svm_predLabel) %>% distinct()

md_list = list()
for(i in 1:nrow(md)) {
  md.sub = md[i,]
  
  n_cols = length(unlist(stringi::stri_split_coll(md[i,"svm_predLabel"],"|")))
  temp_df = do.call(rbind,replicate(n_cols,md.sub,simplify=FALSE))
  temp_df$svm_predLabel = unlist(stringi::stri_split_coll(md[i,"svm_predLabel"],"|"))
  temp_df$rank_md = seq(1:n_cols)
  md_list[[i]] = temp_df
}

md_all = do.call(rbind, md_list)

md_all = md_all %>% dplyr::mutate(subtype=stringr::str_split_i(svm_predLabel,"[,]",1),
                                  score = stringr::str_split_i(svm_predLabel,"[,]",2),
                                  MDALL_score = stringr::str_split_i(score,"[(,)]",2)) %>%
  dplyr::select(sample_id, subtype, MDALL_score,rank_md)


md_all = md_all %>% dplyr::mutate(C=subtype,C=ifelse(grepl("MEF2D",C),"MEF2D",C),
                                  C=ifelse(grepl("iAM",C),"iAMP21",C),
                                  C=ifelse(grepl("TCF3",C),"TCF3::PBX1",C),
                                  C=ifelse(grepl("yperdiploid",C),"Hyperdiploid-group",C),
                                  C=ifelse(grepl("aploid",C),"Hyperdiploid-group",C),
                                  C=ifelse(grepl("ypodiploid",C),"Low-hypodiploid",C),
                                  C=ifelse(grepl("Ph",C),"Ph-group",C),
                                  C=ifelse(grepl("KMT2A",C),"KMT2A",C),
                                  C=ifelse(grepl("ZNF384",C),"ZNF384",C),
                                  C=ifelse(grepl("iAM",C),"iAMP21",C),
                                  C=ifelse(grepl("NUTM1",C),"NUTM1",C),
                                  C=ifelse(grepl("ETV6",C),"ETV6::RUNX1-group",C), 
                                  MDALL_call=C, MDALL_score = as.numeric(MDALL_score)) %>% dplyr::select(sample_id,MDALL_call,MDALL_score,rank_md)
#only top scoring class
md_all = md_all %>% dplyr::filter(rank_md == 1)

##################### Pre-process All-Catcher ###############################################################
ac = ac %>% dplyr::mutate(C=Prediction,AllCatcher_terminal="na",
                          AllCatcher_terminal=ifelse(grepl("Ph-like",C),"Ph-like",AllCatcher_terminal),
                          AllCatcher_terminal=ifelse(grepl("ETV6::RUNX1-like",C),"ETV6::RUNX1-like",AllCatcher_terminal),
                          C=ifelse(grepl("MEF2D",C),"MEF2D",C),
                          C=ifelse(grepl("iAM",C),"iAMP21",C),
                          C=ifelse(grepl("TCF3",C),"TCF3::PBX1",C),
                          C=ifelse(grepl("yperdiploid",C),"Hyperdiploid-group",C),
                          C=ifelse(grepl("aploid",C),"Hyperdiploid-group",C),
                          C=ifelse(grepl("Ph",C),"Ph-group",C),
                          C=ifelse(grepl("KMT2A",C),"KMT2A",C),
                          C=ifelse(grepl("ZNF384",C),"ZNF384",C),
                          C=ifelse(grepl("NUTM1",C),"NUTM1",C),
                          C=ifelse(grepl("ETV6",C),"ETV6::RUNX1-group",C),
                          C=ifelse(grepl("ypodiploid",C),"Low-hypodiploid",C),
                          AllCatcher_call=C,AllCatcher_score=Score,AllCatcher_conf=Confidence,sample_id=sample) %>% 
  dplyr::select(sample_id,AllCatcher_call,AllCatcher_terminal,AllCatcher_score,AllCatcher_conf,Sex)


##################### Pre-process All-Sorts ###############################################################
as = as %>% dplyr::rename(sample_id=`...1`) 

as_list = list()
for(i in 1:nrow(as)) {
  as.sub = as[i,]
  n_cols = length(unlist(stringi::stri_split_coll(as[i,"Pred"],",")))
  temp_df = do.call(rbind,replicate(n_cols,as.sub,simplify=FALSE))
  temp_df$Pred = unlist(stringi::stri_split_coll(as[i,"Pred"],","))
  temp_df = temp_df %>% reshape2::melt(id.vars = c("sample_id", "Pred")) %>% arrange(desc(value))
  temp_df$rank_as = seq(1:nrow(temp_df))
  temp_df = temp_df %>% dplyr::mutate(Pred = ifelse((rank_as == 1 & value >= low_conf), as.character(variable), "Unclassified")) %>% 
    dplyr::filter(rank_as == 1)
  as_list[[i]] = temp_df
}

as_all = do.call(rbind, as_list)

as_all = as_all %>% dplyr::mutate(value=ifelse(Pred == "Unclassified",0,value)) %>%
  dplyr::mutate(C=Pred,AllSorts_terminal="na",
                AllSorts_terminal=ifelse(grepl("Ph-like",C),"Ph-like",AllSorts_terminal),
                AllSorts_terminal=ifelse(grepl("ETV6-RUNX1-like",C),"ETV6::RUNX1-like",AllSorts_terminal),
                C=ifelse(grepl("MEF2D",C),"MEF2D",C),
                C=ifelse(grepl("iAM",C),"iAMP21",C),
                C=ifelse(grepl("TCF3",C),"TCF3::PBX1",C),
                C=ifelse(grepl("yperdiploid",C),"Hyperdiploid-group",C),
                C=ifelse(grepl("haploid",C),"Hyperdiploid-group",C),
                C=ifelse(grepl("Ph",C),"Ph-group",C),
                C=ifelse(grepl("KMT2A",C),"KMT2A",C),
                C=ifelse(grepl("ZNF384",C),"ZNF384",C),
                C=ifelse(grepl("iAM",C),"iAMP21",C),
                C=ifelse(grepl("NUTM1",C),"NUTM1",C),
                C=ifelse(grepl("ETV6",C),"ETV6::RUNX1-group",C),
                C=ifelse(grepl("ypodiploid",C),"Low-hypodiploid",C),
                AllSorts_call=C,AllSorts_score = value) %>% dplyr::select(sample_id,AllSorts_call,AllSorts_terminal,AllSorts_score,rank_as) %>% distinct()

merged_calls = dplyr::left_join(ac,as_all, by = c("sample_id" = "sample_id"), multiple = "all") %>% dplyr::left_join(md_all, by = c("sample_id" = "sample_id"), multiple = "all")


##############################################################################################################
###################### Apply rules to combine calls and generate confidence of calls    ######################
##############################################################################################################

##High confidence
#All 3 call the same group and atleast 1 calls it with > 0.8 threshold

merged_calls = merged_calls %>% dplyr::mutate(final_class="unclassified",final_conf="unclassified") %>% 
  dplyr::mutate(final_conf=ifelse(AllSorts_call == AllCatcher_call & AllCatcher_call == MDALL_call & 
                                    (AllSorts_score >= hi_conf | AllCatcher_score >= hi_conf  | MDALL_score >= hi_conf) &
                                    AllSorts_score >= low_conf & AllCatcher_score >= low_conf & MDALL_score >= low_conf,"hi-conf",final_conf )) %>% 
  dplyr::mutate(final_class = ifelse(final_conf == "hi-conf", AllSorts_call, final_class))

##Low confidence
#All 3 call the same group but with low-confidence
#####################################################  Add additional score thresholds below each caller should have > lo-conf threshold #####################
merged_calls = merged_calls %>% 
  dplyr::mutate(final_conf=ifelse(AllSorts_call == AllCatcher_call & AllCatcher_call == MDALL_call & 
                                    AllSorts_score >= low_conf & AllCatcher_score >= low_conf & MDALL_score >= low_conf &
                                    final_conf == "unclassified","low-conf",final_conf),
                final_class = ifelse(final_conf == "low-conf", AllSorts_call, final_class))

# 2 of 3 callers call it the same group with atleast 1 calling with > hi_conf 
merged_calls = merged_calls %>% 
  dplyr::mutate(final_conf=ifelse(AllSorts_call == AllCatcher_call & (AllSorts_score >= hi_conf | AllCatcher_score >= hi_conf) & 
                                    AllSorts_score >= low_conf & AllCatcher_score >= low_conf &
                                    MDALL_score < hi_conf & 
                                    final_conf == "unclassified" ,"low-conf",final_conf ),
                final_class = ifelse(final_conf == "low-conf" & final_class == "unclassified", AllSorts_call, final_class))

merged_calls = merged_calls %>% 
  dplyr::mutate(final_conf=ifelse(AllSorts_call == MDALL_call & (AllSorts_score >= hi_conf | MDALL_score >= hi_conf) & 
                                    AllSorts_score >= low_conf & MDALL_score >= low_conf &
                                    AllCatcher_score < hi_conf &
                                    final_conf == "unclassified" ,"low-conf",final_conf ),
                final_class = ifelse(final_conf == "low-conf" & final_class == "unclassified", AllSorts_call, final_class))

merged_calls = merged_calls %>% 
  dplyr::mutate(final_conf=ifelse(AllCatcher_call == MDALL_call & (AllCatcher_score >= hi_conf | MDALL_score >= hi_conf) &
                                    AllCatcher_score >= low_conf & MDALL_score >= low_conf &
                                    AllSorts_score < hi_conf & 
                                    final_conf == "unclassified" ,"low-conf",final_conf ),
                final_class = ifelse(final_conf == "low-conf" & final_class == "unclassified", AllCatcher_call, final_class))

##############################################################################################################

#When multiple calls are reported by any of the algorithms, keep the call that generates the highest confidence call
merged_calls = merged_calls %>% group_by(sample_id) %>% dplyr::arrange((final_conf)) %>% dplyr::slice(1)

#Remove multiple unclassified calls for the same sample and report terminal class if present
merged_calls = merged_calls %>% dplyr::filter(!(final_class == "unclassified" & (rank_md > 1 | rank_as > 1))) %>%
  dplyr::mutate(final_terminal_class = ifelse(AllCatcher_terminal == AllSorts_terminal & AllSorts_terminal != "na", AllSorts_terminal, "na")) %>% distinct()

#if final class is unclassified, change terminal class to "na"
merged_calls = merged_calls %>% dplyr::mutate(final_terminal_class = ifelse(final_class == "unclassified", "na" ,final_terminal_class))

#Create final report
final_calls = merged_calls %>% dplyr::select(sample_id, final_class, final_conf, final_terminal_class) %>% distinct()

#Write the output file in current directory
date_suffix = format(Sys.time(), "%m%d%Y")

cat(sprintf("Writing output files \n%s/B-ALL_merged_calls_%s.txt \n%s/B-ALL_final_calls_%s.txt \n",getwd(),date_suffix,getwd(),date_suffix))

write_tsv(merged_calls,sprintf("B-ALL_merged_calls_%s.txt",date_suffix))
write_tsv(final_calls,sprintf("B-ALL_final_calls_%s.txt",date_suffix))





