# syntax=docker/dockerfile:1
#
# B-ALL RNA-Seq Classifier — one image with the Node server, the R pipeline
# (ALLCatchR, MDALL, Rphenograph + deps) and an isolated Python 3.8 env for ALLSorts.
#
# Build (from this directory):   docker build --platform linux/amd64 -t ball-classifier .
# Run:                           docker compose up -d        (see README "Docker")
#
# Base: Bioconductor 3.20 on R 4.4 (Ubuntu 24.04). It ships the system libraries the
# R stack needs and serves pre-built binaries for CRAN/Bioc packages, so the R install
# takes minutes rather than hours. Node 20 and CPython 3.8 are copied in from their
# official images instead of being installed via third-party apt repos.

FROM python:3.8-slim-bookworm AS py38
FROM node:20-bookworm-slim   AS node20

FROM bioconductor/bioconductor_docker:RELEASE_3_20

# ---------------------------------------------------------------------------
# R packages (done first so later layers never invalidate this slow step)
#   CRAN/Bioc deps for the pipeline scripts plus everything ALLCatchR, MDALL and
#   Rphenograph import. The three GitHub packages are pinned to the exact commits
#   installed on the development machine and fetched as tarballs (no GitHub API
#   rate limits, no token needed).
# ---------------------------------------------------------------------------
RUN Rscript -e ' \
  pkgs <- c( \
    "dplyr","stringr","tidyverse","optparse","getopt","progress","vroom", \
    "stringi","reshape2","jsonlite","uwot","remotes","rlang", \
    "SummarizedExperiment","DESeq2","SingleR","singscore", \
    "tidyr","missForest","ggplot2","ggrepel","cowplot","caret","Seurat", \
    "irlba","igraph","LiblineaR","umap","shiny","shinydashboard","shinyjs", \
    "shinyFeedback","data.table","randomForest","kknn","ranger","RANN","Rcpp"); \
  BiocManager::install(pkgs, ask = FALSE, update = FALSE); \
  missing <- setdiff(pkgs, rownames(installed.packages())); \
  if (length(missing)) stop("Failed to install: ", paste(missing, collapse = ", ")) \
' && rm -rf /tmp/Rtmp* /tmp/downloaded_packages

RUN Rscript -e ' \
  gh <- function(repo, sha) sprintf("https://github.com/%s/archive/%s.tar.gz", repo, sha); \
  remotes::install_url(gh("JinmiaoChenLab/Rphenograph", "0298487f0ee13aac55eb77d19992f6bd878ba2fc"), upgrade = "never"); \
  remotes::install_url(gh("ThomasBeder/ALLCatchR",      "1fec6adc0857f666f952095a55d672eac5dd35b5"), upgrade = "never"); \
  remotes::install_url(gh("vyellapa/MD-ALL",            "65ce346b6efc63550e085c7a5fc75931bfe61acc"), upgrade = "never"); \
  for (p in c("Rphenograph","ALLCatchR","MDALL")) suppressPackageStartupMessages(library(p, character.only = TRUE)); \
  stopifnot(exists("obj_1821"), exists("obj_234_HTSeq"), exists("models_svm")) \
' && rm -rf /tmp/Rtmp* /tmp/downloaded_packages

# ---------------------------------------------------------------------------
# Node.js 20 (runs server.js) — binary + npm from the official image
# ---------------------------------------------------------------------------
COPY --from=node20 /usr/local/bin/node /usr/local/bin/node
COPY --from=node20 /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -sf /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
 && ln -sf /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
 && node --version && npm --version

# ---------------------------------------------------------------------------
# ALLSorts (Python 3.8). Ubuntu 24.04 has no 3.8, so CPython is copied from the
# official image and given the shared libs it links against. Version pins mirror
# the working conda env on the dev machine and upstream env/allsorts.yml — the
# bundled model pickle was trained against scikit-learn 0.22.1, so don't bump
# these casually. These old wheels only exist for x86_64: build with
# --platform linux/amd64.
# ---------------------------------------------------------------------------
COPY --from=py38 /usr/local/bin/python3.8            /usr/local/bin/python3.8
COPY --from=py38 /usr/local/lib/python3.8            /usr/local/lib/python3.8
COPY --from=py38 /usr/local/lib/libpython3.8.so.1.0  /usr/local/lib/libpython3.8.so.1.0
COPY --from=py38 /usr/local/include/python3.8        /usr/local/include/python3.8
RUN apt-get update && apt-get install -y --no-install-recommends \
      libssl3 libffi8 libbz2-1.0 liblzma5 libsqlite3-0 zlib1g libexpat1 libreadline8 libncursesw6 libuuid1 \
 && apt-get clean && rm -rf /var/lib/apt/lists/* \
 && ldconfig \
 && python3.8 -c "import ssl, sqlite3, lzma, bz2, zlib, ctypes, hashlib" \
 && python3.8 -m venv /opt/allsorts
RUN /opt/allsorts/bin/pip install --no-cache-dir --upgrade "pip<24.1" \
 && /opt/allsorts/bin/pip install --no-cache-dir \
      "numpy==1.18.1" "scipy==1.4.1" "pandas==1.0.3" "scikit-learn==0.22.1" \
      "joblib==0.15.1" "llvmlite==0.35.0" "numba==0.52.0" "umap-learn==0.4.4" \
      "matplotlib==3.2.1" "plotly==4.14.3" "kaleido==0.1.0" \
 && /opt/allsorts/bin/pip install --no-cache-dir --no-deps \
      "git+https://github.com/Oshlack/ALLSorts.git@f215e74984d1d27f0cb9bc8ef2acff512786c5ab" \
 && /opt/allsorts/bin/ALLSorts --help > /dev/null
ENV ALLSORTS_BIN=/opt/allsorts/bin/ALLSorts \
    MPLBACKEND=Agg \
    NUMBA_CACHE_DIR=/tmp/numba_cache

# ---------------------------------------------------------------------------
# App
# ---------------------------------------------------------------------------
WORKDIR /app
COPY package.json package-lock.json ./
# The require check guards against npm's known failure mode of exiting 0 after a
# network error ("Exit handler never called") and leaving node_modules half-empty.
RUN npm ci --omit=dev && npm cache clean --force \
 && node -e "require('express'); require('multer'); require('uuid')"

COPY server.js ./
COPY public ./public
COPY scripts ./scripts
COPY resources ./resources

# Run as uid 1000 (required by Hugging Face Spaces; harmless elsewhere). The base
# image already owns uid 1000 as "rstudio", so rename it rather than add a second.
RUN usermod -l app -d /home/app -m rstudio && groupmod -n app rstudio \
 && mkdir -p /app/runs \
 && chown -R app:app /app
USER app

ENV NODE_ENV=production \
    PORT=3000 \
    RUNS_DIR=/app/runs \
    GTF_FILE=/app/resources/gtf1.txt

VOLUME ["/app/runs"]
EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD curl -fsS http://localhost:3000/runs > /dev/null || exit 1

CMD ["node", "server.js"]
