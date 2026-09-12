/**
 * B-ALL Classifier Web Server — Fixed v2
 */

const express    = require('express');
const multer     = require('multer');
const path       = require('path');
const fs         = require('fs');
const { execFile } = require('child_process');
const { v4: uuidv4 } = require('uuid');

const app  = express();
const PORT = process.env.PORT || 3000;

const SCRIPTS_DIR = path.join(__dirname, 'scripts');
const RUNS_DIR    = process.env.RUNS_DIR || path.join(__dirname, 'runs');
const DEFAULT_GTF = process.env.GTF_FILE || path.join(__dirname, 'resources', 'gtf1.txt');
const RUN_MANIFEST = 'run-manifest.json';

fs.mkdirSync(RUNS_DIR, { recursive: true });

const jobs = {};

function sanitizeLabel(value, fallback) {
  return String(value || fallback).replace(/[^a-zA-Z0-9_-]/g, '_');
}

function getManifestPath(runDir) {
  return path.join(runDir, RUN_MANIFEST);
}

function readManifest(runDir) {
  const manifestPath = getManifestPath(runDir);
  if (!fs.existsSync(manifestPath)) return null;

  try {
    return JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  } catch (err) {
    console.warn(`Failed to read manifest: ${manifestPath}`, err.message);
    return null;
  }
}

function persistJob(job) {
  const runDir = path.join(RUNS_DIR, job.runId);
  fs.mkdirSync(runDir, { recursive: true });

  const record = {
    runId: job.runId,
    label: job.label,
    status: job.status,
    log: Array.isArray(job.log) ? job.log : [],
    outputs: Array.isArray(job.outputs) ? job.outputs : [],
    error: job.error || null,
    startedAt: job.startedAt || new Date().toISOString(),
    updatedAt: new Date().toISOString(),
    endedAt: job.endedAt || null
  };

  fs.writeFileSync(getManifestPath(runDir), JSON.stringify(record, null, 2));
}

function listRunOutputs(runDir) {
  if (!fs.existsSync(runDir)) return [];
  return fs.readdirSync(runDir).filter(f =>
    f.startsWith('B-ALL_') || f.startsWith('MDall_output_') ||
    f === 'counts.csv' || f === 'counts.v2.csv'
  );
}

function getRunArtifacts(runDir) {
  if (!fs.existsSync(runDir)) {
    return { hasGeneSearch: false, hasUmap: false, outputs: [], sampleName: null };
  }

  const files = fs.readdirSync(runDir);
  const quantFile = files.find(f =>
    f.endsWith('_dragen.quant.genes.sf') ||
    f === 'quant.sf' ||
    f.endsWith('.quant.sf') ||
    f.endsWith('.genes.sf')
  );
  const sampleName = quantFile
    ? quantFile
        .replace(/_dragen\.quant\.genes\.sf$/i, '')
        .replace(/\.quant\.sf$/i, '')
        .replace(/\.genes\.sf$/i, '')
        .replace(/\.sf$/i, '')
    : null;

  return {
    hasGeneSearch: files.some(f => f.startsWith('vst_data_') && f.endsWith('.rds')),
    hasUmap: files.some(f => f.startsWith('umap_data_') && f.endsWith('.json')),
    outputs: listRunOutputs(runDir),
    sampleName
  };
}

function buildRunSummary(runId, job) {
  const runDir = path.join(RUNS_DIR, runId);
  const artifacts = getRunArtifacts(runDir);
  const stats = fs.existsSync(runDir) ? fs.statSync(runDir) : null;
  const outputs = job?.outputs?.length ? job.outputs : artifacts.outputs;

  return {
    runId,
    label: job?.label || runId,
    sampleName: artifacts.sampleName,
    status: job?.status || (outputs.length ? 'completed' : 'unknown'),
    startedAt: job?.startedAt || stats?.birthtime?.toISOString?.() || stats?.mtime?.toISOString?.() || new Date().toISOString(),
    updatedAt: job?.updatedAt || stats?.mtime?.toISOString?.() || null,
    endedAt: job?.endedAt || null,
    log: job?.log || [],
    outputs,
    error: job?.error || null,
    hasGeneSearch: artifacts.hasGeneSearch,
    hasUmap: artifacts.hasUmap
  };
}

function listStoredRuns() {
  if (!fs.existsSync(RUNS_DIR)) return [];

  return fs.readdirSync(RUNS_DIR, { withFileTypes: true })
    .filter(entry => entry.isDirectory())
    .map(entry => {
      const runId = entry.name;
      const manifest = readManifest(path.join(RUNS_DIR, runId));
      return buildRunSummary(runId, manifest);
    })
    .sort((a, b) => new Date(b.startedAt) - new Date(a.startedAt));
}

function hydrateJobsFromDisk() {
  for (const run of listStoredRuns()) {
    const job = {
      runId: run.runId,
      label: run.label,
      status: run.status,
      log: run.log || [],
      outputs: run.outputs || [],
      error: run.error || null,
      startedAt: run.startedAt,
      updatedAt: run.updatedAt,
      endedAt: run.endedAt
    };

    if (job.status === 'queued' || job.status === 'running') {
      job.status = 'interrupted';
      job.error = job.error || 'Server restarted before the run finished.';
      job.endedAt = new Date().toISOString();
      job.log.push(`[${job.endedAt}] Server restarted before the run finished. Marking run as interrupted.`);
      persistJob(job);
    }

    jobs[run.runId] = job;
  }
}

// Optional password gate. Set APP_PASSWORD (and optionally APP_USER, default "admin")
// to require HTTP basic auth on every route, including static files and downloads.
// Leave APP_PASSWORD unset for an open instance (e.g. behind your own SSO proxy).
const APP_PASSWORD = process.env.APP_PASSWORD || '';
const APP_USER     = process.env.APP_USER || 'admin';
// Fail closed on Hugging Face: Spaces set SPACE_ID in the environment. Never serve
// sample data from a Space that has no password configured.
if (process.env.SPACE_ID && !APP_PASSWORD) {
  console.error('Refusing to start: running on Hugging Face Spaces without APP_PASSWORD.');
  console.error('Add APP_PASSWORD as a secret in the Space settings, then restart the Space.');
  process.exit(1);
}
if (APP_PASSWORD) {
  const crypto = require('crypto');
  const expected = Buffer.from(`${APP_USER}:${APP_PASSWORD}`);
  app.use((req, res, next) => {
    const header = req.headers.authorization || '';
    const given = header.startsWith('Basic ') ? Buffer.from(header.slice(6), 'base64') : Buffer.alloc(0);
    const ok = given.length === expected.length && crypto.timingSafeEqual(given, expected);
    if (ok) return next();
    res.set('WWW-Authenticate', 'Basic realm="B-ALL Classifier", charset="UTF-8"');
    res.status(401).send('Authentication required');
  });
}

app.use(express.static(path.join(__dirname, 'public')));
app.use(express.json());

hydrateJobsFromDisk();

app.get('/', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

// Inject runId before Multer destination fires
app.use('/upload', (req, res, next) => {
  req.runId = uuidv4();
  next();
});

const storage = multer.diskStorage({
  destination: (req, file, cb) => {
    const runDir = path.join(RUNS_DIR, req.runId);
    fs.mkdirSync(runDir, { recursive: true });
    cb(null, runDir);
  },
  filename: (req, file, cb) => cb(null, file.originalname)
});

// Accept only the user-provided inputs. bll_v3.R generates predictions.tsv
// and allsorts_results/probabilities.csv inside the run directory.
const upload = multer({
  storage,
  fileFilter: (req, file, cb) => {
    const allowed = ['quantSf', 'gtfFile'];
    if (allowed.includes(file.fieldname)) return cb(null, true);
    cb(new multer.MulterError('LIMIT_UNEXPECTED_FILE', file.fieldname));
  },
  limits: { fileSize: 500 * 1024 * 1024 }
});

app.post('/upload', upload.fields([
  { name: 'quantSf',    maxCount: 1 },
  { name: 'gtfFile',    maxCount: 1 }
]), async (req, res) => {

  const runId  = req.runId;
  const runDir = path.join(RUNS_DIR, runId);

  try {
    if (!req.files?.['quantSf'])    return res.status(400).json({ error: 'quantSf (quant.sf) is required.' });

    jobs[runId] = {
      runId,
      status: 'queued',
      label: sanitizeLabel(req.body.runLabel, runId),
      log: [],
      outputs: [],
      error: null,
      startedAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
      endedAt: null
    };
    persistJob(jobs[runId]);

    // FIX: v2 used only filename, not full path — GTF would not be found
    let gtfPath = DEFAULT_GTF;
    if (req.files?.['gtfFile']) {
      gtfPath = req.files['gtfFile'][0].path;  // full absolute path
    }

    const runLabel       = jobs[runId].label;
    const lowConf        = parseFloat(req.body.lowConf)  || 0.4;
    const highConf       = parseFloat(req.body.highConf) || 0.8;

    res.json({ runId, message: 'Job queued.' });

    runPipeline({ runId, runDir, runLabel, gtfPath, lowConf, highConf });

  } catch (err) {
    if (jobs[runId]) {
      jobs[runId].status = 'failed';
      jobs[runId].error  = err.message;
      jobs[runId].endedAt = new Date().toISOString();
      persistJob(jobs[runId]);
    }
    if (!res.headersSent) res.status(500).json({ error: err.message, runId });
  }
});

app.get('/status/:runId', (req, res) => {
  const runId = req.params.runId;
  const job = jobs[runId] || readManifest(path.join(RUNS_DIR, runId));
  if (!job) return res.status(404).json({ error: 'Job not found' });
  res.json(buildRunSummary(runId, job));
});

app.get('/runs', (req, res) => {
  res.json(listStoredRuns());
});

app.get('/download/:runId/:filename', (req, res) => {
  const { runId, filename } = req.params;
  if (filename.includes('..') || filename.includes('/')) return res.status(400).send('Invalid filename');
  const filePath = path.join(RUNS_DIR, runId, filename);
  if (!fs.existsSync(filePath)) return res.status(404).send('File not found');
  res.download(filePath);
});

app.get('/api/search/:runId/:gene', (req, res) => {
  const { runId } = req.params;
  const gene = String(req.params.gene || '').trim();
  const runDir   = path.join(RUNS_DIR, runId);
  if (!gene) return res.status(400).json({ error: 'Gene is required.' });

  execFile(
    'Rscript',
    [path.join(SCRIPTS_DIR, 'get_gene_data.R'), runDir, gene],
    { cwd: runDir },
    (error, stdout, stderr) => {
      if (error) {
        return res.status(500).json({
          error: stderr?.trim() || stdout?.trim() || error.message
        });
      }

      try {
        const dataPath = path.join(runDir, 'search_results.json');
        if (!fs.existsSync(dataPath)) {
          throw new Error('Gene expression JSON was not generated.');
        }
        res.json(JSON.parse(fs.readFileSync(dataPath, 'utf8')));
      } catch (err) {
        res.status(500).json({ error: err.message });
      }
    }
  );
});

app.get('/api/umap/:runId', (req, res) => {
  const runDir = path.join(RUNS_DIR, req.params.runId);
  try {
    const files    = fs.readdirSync(runDir);
    const umapFile = files.find(f => f.startsWith('umap_data') && f.endsWith('.json'));
    if (umapFile) {
      const umapPath = path.join(runDir, umapFile);
      const umapData = JSON.parse(fs.readFileSync(umapPath, 'utf8'));
      const mergedFile = files.find(f => f.startsWith('B-ALL_merged_calls_') && f.endsWith('.txt'));
      const finalFile = files.find(f => f.startsWith('B-ALL_final_calls_') && f.endsWith('.txt'));
      let finalCalls = [];

      if (mergedFile) {
        const mergedPath = path.join(runDir, mergedFile);
        const [headerLine, ...rows] = fs.readFileSync(mergedPath, 'utf8').trim().split(/\r?\n/);
        const headers = headerLine.split('\t');
        const mergedRows = rows
          .filter(Boolean)
          .map(line => Object.fromEntries(line.split('\t').map((value, index) => [headers[index], value])));

        const queryPoint = umapData.find(point => point.is_query);
        if (queryPoint) {
          const scoreRow = mergedRows.find(row => row.sample_id === queryPoint.sample_id);
          if (scoreRow) {
            Object.assign(queryPoint, {
              allcatcher_call: scoreRow.AllCatcher_call,
              allcatcher_terminal: scoreRow.AllCatcher_terminal,
              allcatcher_score: Number(scoreRow.AllCatcher_score),
              allcatcher_conf: scoreRow.AllCatcher_conf,
              allsorts_call: scoreRow.AllSorts_call,
              allsorts_terminal: scoreRow.AllSorts_terminal,
              allsorts_score: Number(scoreRow.AllSorts_score),
              mdall_call: scoreRow.MDALL_call,
              mdall_score: Number(scoreRow.MDALL_score),
              final_class: scoreRow.final_class,
              final_conf: scoreRow.final_conf
            });
          }
        }
      }

      if (finalFile) {
        const finalPath = path.join(runDir, finalFile);
        const lines = fs.readFileSync(finalPath, 'utf8').trim().split(/\r?\n/).filter(Boolean);
        if (lines.length > 1) {
          const headers = lines[0].split('\t');
          finalCalls = lines.slice(1).map(line =>
            Object.fromEntries(line.split('\t').map((value, index) => [headers[index], value]))
          );
        }
      }

      return res.json({ umap: umapData, finalCalls });
    }
    res.status(404).json({ error: 'UMAP data not found.' });
  } catch (err) {
    res.status(500).json({ error: 'Failed to retrieve UMAP data.' });
  }
});

// ── Pipeline ──────────────────────────────────────────────────────────────────
async function runPipeline({ runId, runDir, runLabel, gtfPath, lowConf, highConf }) {
  const job = jobs[runId];
  function log(msg) {
    const line = `[${new Date().toISOString()}] ${msg}`;
    console.log(line);
    job.log.push(line);
    job.updatedAt = new Date().toISOString();
    persistJob(job);
  }

  try {
    job.status = 'running';
    job.error = null;
    persistJob(job);
    log(`Pipeline started — ${runLabel}`);

    // Step 1: bll_v3.R
    // FIX: v2 used wrong flags (--sample, --counts, --gtf)
    //      Correct flags per bll_v3.R optparse: -i (indir), -g (gtf), -o (output suffix)
    log('Step 1/2 — bll_v3.R…');
    await runR(
      path.join(SCRIPTS_DIR, 'bll_v3.R'),
      ['-i', runDir, '-g', gtfPath, '-o', runLabel],
      { cwd: runDir },
      log
    );
    log('bll_v3.R done.');

    const mdallOutput = path.join(runDir, `MDall_output_${runLabel}.txt`);
    if (!fs.existsSync(mdallOutput)) {
      throw new Error(`Expected MDALL output not found: MDall_output_${runLabel}.txt`);
    }

    const allcatcherPath = path.join(runDir, 'predictions.tsv');
    if (!fs.existsSync(allcatcherPath)) {
      throw new Error('Expected ALLCatchR output not found: predictions.tsv');
    }

    const allsortsDest = path.join(runDir, 'allsorts_results', 'probabilities.csv');
    if (!fs.existsSync(allsortsDest)) {
      throw new Error('Expected ALLSorts output not found: allsorts_results/probabilities.csv');
    }

    // Step 2: BALL_classifier_postProcess_v5.R
    // Consume ALLCatchR and ALLSorts outputs generated by bll_v3.R.
    log('Step 2/2 — BALL_classifier_postProcess_v5.R…');
    await runR(
      path.join(SCRIPTS_DIR, 'BALL_classifier_postProcess_v5.R'),
      ['-m', mdallOutput, '-c', allcatcherPath, '-s', allsortsDest, '-l', String(lowConf), '-u', String(highConf)],
      { cwd: runDir },
      log
    );
    log('Post-processing done.');

    job.outputs = listRunOutputs(runDir);

    job.status = 'completed';
    job.endedAt = new Date().toISOString();
    persistJob(job);
    log(`Done. Files: ${job.outputs.join(', ')}`);

  } catch (err) {
    job.status = 'failed';
    job.error  = err.message;
    job.endedAt = new Date().toISOString();
    persistJob(job);
    log(`ERROR: ${err.message}`);
  }
}

function runR(scriptPath, args, options, log) {
  return new Promise((resolve, reject) => {
    const proc = execFile('Rscript', [scriptPath, ...args], options, (error, stdout, stderr) => {
      if (error) reject(new Error(`Rscript exited ${error.code}: ${stderr || error.message}`));
      else resolve(stdout);
    });
    proc.stdout.on('data', d => d.toString().split('\n').filter(Boolean).forEach(l => log(`  [R] ${l}`)));
    proc.stderr.on('data', d => d.toString().split('\n').filter(Boolean).forEach(l => log(`  [R stderr] ${l}`)));
  });
}

app.use((req, res) => res.status(404).json({ error: 'Not found' }));

app.listen(PORT, () => {
  console.log(`\n🧬 B-ALL Classifier → http://localhost:${PORT}`);
  console.log(`   GTF:     ${DEFAULT_GTF}`);
  console.log(`   Scripts: ${SCRIPTS_DIR}`);
  console.log(`   Auth:    ${APP_PASSWORD ? `basic auth, user "${APP_USER}"` : 'NONE (open to anyone who can reach this port)'}\n`);
});

module.exports = app;
