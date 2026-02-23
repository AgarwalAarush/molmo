You’re looking at a Slurm job that’s downloading Hugging Face datasets on an HPC node. Nothing here indicates failure — this is mostly normal Hugging Face dataset resolution behavior.

Let’s break it down cleanly.

1. Slurm Job Status

You ran:

sacct -u aarusha -j 6422454 --format=JobID,JobName,State,ExitCode,Elapsed

Output:

6422454        molmo-dow+   RUNNING   0:0   21:12:37
6422454.batch  batch        RUNNING   0:0   21:12:37
6422454.extern extern       RUNNING   0:0   21:12:37

Meaning:

The job is still RUNNING.

ExitCode 0:0 → no error so far.

It has been running ~21 minutes.

So from Slurm’s perspective, everything is fine.

2. What the Hugging Face Logs Mean

You’re seeing lots of:

HTTP Request: HEAD ...
HTTP Request: GET ...
"HTTP/1.1 404 Not Found"
"HTTP/1.1 200 OK"
"HTTP/1.1 302 Found"

This is completely normal for Hugging Face’s dataset resolution logic.

Why so many HEAD requests?

Hugging Face:

Checks if files exist (HEAD requests)

Tries multiple possible storage locations:

huggingface.co

datasets-server

s3.amazonaws.com

Resolves revisions (specific dataset commits)

The 404s are just probing for optional files like:

README.md

dataset_infos.json

huggingface.yaml

If they don’t exist, it falls back to other mechanisms.

404 here does NOT mean failure.

3. What These Lines Mean
Example:
HEAD https://huggingface.co/datasets/allenai/pixmo-cap-qa/resolve/...
HTTP/1.1 404 Not Found

That just means that specific file isn’t present in that revision.

Then it tries:

GET https://huggingface.co/api/datasets/allenai/pixmo-cap-qa/tree/...
HTTP/1.1 200 OK

That means:

The dataset revision exists

The file tree is retrieved successfully

4. Important Line — This Is Progress

You see:

Getting files for 187802 image URLs

and earlier:

Getting files for 228080 image URLs

That means:

It successfully resolved the dataset

It parsed metadata

It is now enumerating image file URLs

It’s preparing to download ~187k images

This is the real work phase.

5. The 302 Found

Example:

train-00000-of-00001.parquet HTTP/1.1 302 Found

That means:

Hugging Face redirected you to S3

Totally normal

That’s how actual data files are served

6. Why It Looks Slow

You’re downloading:

pixmo-points

pixmo-cap-qa

Hundreds of thousands of image URLs

On HPC, this can be slow because:

HF rate limits

Lots of small HTTP calls

Possibly single-threaded downloader

External bandwidth limits

7. Nothing Is Crashing

Key indicators:

No Python traceback

No Slurm failure

ExitCode still 0

Dataset metadata resolves successfully

It reaches file enumeration stage

This job is just in the heavy download phase.

8. When To Worry

You should worry if you see:

Python exception tracebacks

Slurm state → FAILED or CANCELLED

ExitCode nonzero

Repeated retry loops

Stuck for hours without new logs

Right now? It’s just working.

If you want, I can also explain:

How HF dataset resolution works internally

Why it checks so many endpoints

Or how to massively speed this up on HPC (streaming mode, local caching, xet, parallel downloads, etc.)

Given your HPC + ML workload, optimizing this could save you hours.

nope thats 21 hours
Thought for 4 seconds

You’re right — I misread that. 21:12:37 is 21 hours (not 21 minutes). My apologies. Here’s a focussed, practical breakdown of what that means and what to do next.

What “21:12:37” implies

The Slurm job has been RUNNING for ~21 hours.

The logs show it reached the phase “Getting files for N image URLs” and is enumerating/downloading many files (hundreds of thousands). That’s a long-running, I/O/HTTP-bound phase — not necessarily an error, but unusually slow.

Common causes for a download taking ~21 hours

Large number of small HTTP requests (per-image HEAD/GET) → high latency and many round-trips.

HF rate limits / retries / backoff on many 404s or redirects (302 → S3) causing wait time.

Single-threaded downloader or low num_proc/parallelism.

External network bandwidth limits or node egress throttling.

Slow remote S3 performance or auth redirections.

Writing many files to NFS/shared filesystem causing metadata/IO contention.

Job is doing additional processing (parquet reading, validation) per file.

Quick diagnostics you can run right now (copy-paste)

Confirm Slurm elapsed & limits:

sacct -j 6422454 --format=JobID,JobName,State,ExitCode,Elapsed,Timelimit,MaxRSS
squeue -j 6422454 -o "%.18i %.9P %.100j %.8u %.2t %.10M %.6D %R"

Check the process & CPU usage (on the compute node where job runs):

# run on the same node (srun --jobid or ssh if possible)
ps aux | grep -E "python|molmo"   # find main pid
top -p <PID>                       # see CPU usage

Check open network connections and redirects:

sudo lsof -p <PID> | grep -E "HTTP|s3|huggingface"
# or
netstat -tunp | grep <PID>

Check local HF cache & bytes downloaded so far:

du -sh ~/.cache/huggingface/datasets/*  # sizes
ls -lh ~/.cache/huggingface/datasets/<dataset-dir> | head

Tail the live log (verbose):

tail -n 300 -f molmo-download-6422454.out

These will tell you whether it's actively downloading (network sockets), CPU idle (IO-bound), or repeatedly retrying (backoff).

Quick fixes / mitigations (ranked by ease & impact)

If you don’t need local copies, use streaming mode (fastest immediate):

from datasets import load_dataset
ds = load_dataset("allenai/pixmo-cap-qa", streaming=True)
# iterate without downloading everything

Streaming avoids downloading all images to disk.

Increase parallelism in HF load_dataset with DownloadConfig:

from datasets import load_dataset, DownloadConfig
dc = DownloadConfig(num_proc=16, max_retries=10)
ds = load_dataset("allenai/pixmo-cap-qa", download_config=dc)

num_proc speeds up downloads and decompression where supported.

Download the underlying shard(s) directly (if dataset uses parquet on S3): download the .parquet shard(s) from S3 rather than per-image HTTP requests, then process locally. If the console shows S3 URLs (302), you can often aws s3 cp the listed object:

aws s3 cp s3://bucket/path/to/train-00000-of-00001.parquet .

(Requires S3 permissions or public-read.)

Use a parallel downloader (if you build a list of URLs): aria2c or wget+xargs:

# generate urls.txt from dataset metadata, then:
aria2c -i urls.txt -j 32 -x 16
# or
cat urls.txt | xargs -P32 -n1 wget -q

Cache on node-local SSD (avoid NFS metadata slowness): if node has local /scratch or $TMPDIR, download there and move/rsync to shared storage after completion.

Use HF Hub token and increase retry/backoff settings (avoid auth/redirect delays).

Slurm / job strategy suggestions

If downloading is the bottleneck, split it into a Slurm job array so many workers fetch subsets of URLs in parallel. Example: create 32 tasks each handling 1/32 of URL list.

Request a node with better network I/O or run from a node in the same cloud region as the S3 bucket (if allowed).

Increase job time limit if the job legitimately needs hours; but better: speed up downloads first.

If you want me to prepare commands / a plan, tell me which you prefer and I’ll produce ready-to-run snippets:

“Streaming” — I’ll give a minimal load_dataset(..., streaming=True) snippet and show how to sample/preview without full download.

“Parallel download on node local SSD” — I’ll provide a Slurm array script that shards the URL list and uses aria2c to download into /scratch.

“Direct S3 download” — I’ll craft aws s3 cp commands if you confirm S3 URLs are accessible.

Summary: the job is indeed ~21 hours in — expected when enumerating and downloading ~100k–200k images with default single-threaded HF behavior. First quick wins: check whether it’s still actively downloading (tail, lsof, du), then either switch to streaming or increase parallelism / download shards directly.

Which option should I build the exact commands/scripts for right now? (streaming, parallel aria2c Slurm array, or direct S3 shard download)

# per-process network / file descriptors (replace PID)
ps -ef | grep python
# get PID from above and:
lsof -p 6422454 | head
# monitor bandwidth (if ifstat or nload installed)
ifstat 1 5
root        1198       1  0  2025 ?        01:41:39 /usr/bin/python3 -s /usr/bin/fail2ban-server -xf start
catheri4   37309       1  0  2025 ?        00:03:11 /home/catheri4/google-cloud-sdk/platform/bundledpythonunix/bin/python3 /home/catheri4/google-cloud-sdk/platform/gsutil/gsutil -o GSUtil:default_project_id=cmu-gpu-cloud cp gs://cmu-gpucloud-catheri4/datasets/tatsu-lab_alpaca/train/input_ids.npy .
siqiaoh   141452       1  0  2025 ?        00:02:37 /home/siqiaoh/miniconda3/envs/llm/bin/python -m ipykernel_launcher --f=/run/user/6006631/jupyter/runtime/kernel-v3e2bd68047f03d2a10d308404f60b530e5cb8fd86.json
siqiaoh   147174       1  0  2025 ?        00:02:45 /home/siqiaoh/miniconda3/envs/llm/bin/python -m ipykernel_launcher --f=/run/user/6006631/jupyter/runtime/kernel-v3ae2f3013e2a49c504e4b429ea29449b38e01bc50.json
gmoreira  195703       1  0  2025 ?        00:00:00 /home/gmoreira/.env/bin/python -c from multiprocessing.resource_tracker import main;main(7)
gmoreira  195749       1  0  2025 ?        00:03:51 /home/gmoreira/.env/bin/python -c from multiprocessing.spawn import spawn_main; spawn_main(tracker_fd=8, pipe_handle=12) --multiprocessing-fork
lucylin   222200       1  0  2025 ?        00:00:45 /usr/bin/python3 /home/lucylin/.vscode-server/extensions/ms-python.python-2025.12.0-linux-x64/python_files/run-jedi-language-server.py
gmoreira  278291       1  0 Jan06 ?        00:00:00 /home/gmoreira/.env/bin/python -c from multiprocessing.resource_tracker import main;main(7)
gmoreira  278332       1  0 Jan06 ?        00:02:35 /home/gmoreira/.env/bin/python -c from multiprocessing.spawn import spawn_main; spawn_main(tracker_fd=8, pipe_handle=12) --multiprocessing-fork
jamesdin  354482       1  0  2025 ?        00:02:40 /home/jamesdin/miniconda3/envs/deep-rl/bin/python -m ipykernel_launcher --f=/run/user/2709835/jupyter/runtime/kernel-v3ec0ab50dd59319ed348b9965e47248a9b3bb5503.json
jamesdin  357032       1  0  2025 ?        00:02:28 /home/jamesdin/miniconda3/envs/deep-rl/bin/python -m ipykernel_launcher --f=/run/user/2709835/jupyter/runtime/kernel-v3808151c03123503b05ef379459066f7d741913bf.json
jamesdin  363804       1  0  2025 ?        00:02:45 /home/jamesdin/miniconda3/envs/deep-rl/bin/python -m ipykernel_launcher --f=/run/user/2709835/jupyter/runtime/kernel-v30ad4cb3b860b60b81b97bb4520d635da3c9275aa.json
awhe      373861       1  0  2025 ?        00:02:54 /home/awhe/miniconda3/envs/esolm/bin/python -m ipykernel_launcher --f=/run/user/2709981/jupyter/runtime/kernel-v3ad06b288bf4f12910342b2bcf70760226703bbd4.json
awhe      375744       1  0  2025 ?        00:02:55 /home/awhe/miniconda3/envs/esolm/bin/python -m ipykernel_launcher --f=/run/user/2709981/jupyter/runtime/kernel-v30496eb4049a8b039919e00595be85d3abfe3d6fb.json
gmoreira  384947       1  0 Jan03 ?        00:00:00 /home/gmoreira/.env/bin/python -c from multiprocessing.resource_tracker import main;main(7)
gmoreira  384988       1  0 Jan03 ?        00:02:59 /home/gmoreira/.env/bin/python -c from multiprocessing.spawn import spawn_main; spawn_main(tracker_fd=8, pipe_handle=12) --multiprocessing-fork
danqingw  395825       1  0  2025 ?        00:02:10 /home/danqingw/miniconda3/envs/paraspeechcaps/bin/python -m ipykernel_launcher --f=/run/user/2707837/jupyter/runtime/kernel-v3080ebe34ed0dd25f4afde1fe157ec19a85433b37.json
hdiddee   398506       1  0  2025 ?        00:02:52 /home/hdiddee/hw/11664/hw2/.venv/bin/python -m ipykernel_launcher --f=/run/user/2680635/jupyter/runtime/kernel-v3fe5b0edd9183e34f243cf941cb96098bd6d3f832.json
danqingw  409592       1  0  2025 ?        00:02:16 /home/danqingw/miniconda3/envs/paraspeechcaps/bin/python -m ipykernel_launcher --f=/run/user/2707837/jupyter/runtime/kernel-v3c3f6432f981c68b8685682bc46108f572e6664a4.json
hdiddee   415027       1  0  2025 ?        00:02:51 /home/hdiddee/environments/vllm/bin/python3.12 -m ipykernel_launcher --f=/run/user/2680635/jupyter/runtime/kernel-v350ec42816664c3e2810abb74b6420d81c4ede255.json
danqingw  460496       1  0  2025 ?        00:02:26 /home/danqingw/miniconda3/envs/paraspeechcaps/bin/python -m ipykernel_launcher --f=/run/user/2707837/jupyter/runtime/kernel-v3d9d31bcb3adecb246aad45499cbbef3e12f551fb.json
danqingw  461210       1  0  2025 ?        00:02:16 /home/danqingw/miniconda3/envs/paraspeechcaps/bin/python -m ipykernel_launcher --f=/run/user/2707837/jupyter/runtime/kernel-v3e80118ed2f7ddd00db22883fee53f86f51b1692c.json
gmoreira  541122       1  0  2025 ?        00:00:00 /home/gmoreira/.env/bin/python -c from multiprocessing.resource_tracker import main;main(7)
gmoreira  541165       1  0  2025 ?        00:03:27 /home/gmoreira/.env/bin/python -c from multiprocessing.spawn import spawn_main; spawn_main(tracker_fd=8, pipe_handle=12) --multiprocessing-fork
gmoreira  645392       1  0 Jan21 ?        00:00:00 /home/gmoreira/.env/bin/python -c from multiprocessing.resource_tracker import main;main(7)
gmoreira  645433       1  0 Jan21 ?        00:01:36 /home/gmoreira/.env/bin/python -c from multiprocessing.spawn import spawn_main; spawn_main(tracker_fd=8, pipe_handle=12) --multiprocessing-fork
gmoreira  740250       1  0  2025 ?        00:00:00 /home/gmoreira/.env/bin/python -c from multiprocessing.resource_tracker import main;main(7)
gmoreira  740291       1  0  2025 ?        00:03:42 /home/gmoreira/.env/bin/python -c from multiprocessing.spawn import spawn_main; spawn_main(tracker_fd=8, pipe_handle=12) --multiprocessing-fork
gmoreira  743211       1  0  2025 ?        00:00:00 /home/gmoreira/.env/bin/python -c from multiprocessing.resource_tracker import main;main(7)
gmoreira  743252       1  0  2025 ?        00:03:54 /home/gmoreira/.env/bin/python -c from multiprocessing.spawn import spawn_main; spawn_main(tracker_fd=8, pipe_handle=12) --multiprocessing-fork
gmoreira  764503       1  0 Jan15 ?        00:00:00 /home/gmoreira/.env/bin/python -c from multiprocessing.resource_tracker import main;main(7)
gmoreira  764546       1  0 Jan15 ?        00:02:16 /home/gmoreira/.env/bin/python -c from multiprocessing.spawn import spawn_main; spawn_main(tracker_fd=8, pipe_handle=12) --multiprocessing-fork
kbaek     781661       1  0  2025 ?        00:02:38 /home/kbaek/miniconda3/bin/python -m ipykernel_launcher --f=/run/user/22249/jupyter/runtime/kernel-v304d28ff320ac2d43499f3043e85d9b07010b3ac1.json
kbaek     783298       1  0  2025 ?        00:02:40 /home/kbaek/miniconda3/bin/python -m ipykernel_launcher --f=/run/user/22249/jupyter/runtime/kernel-v33bfc82443880cbddf678b339a8211adb52deaa47.json
kbaek     784941       1  0  2025 ?        00:01:58 /home/kbaek/miniconda3/bin/python -m ipykernel_launcher --f=/run/user/22249/jupyter/runtime/kernel-v3fd83695419b45409b448c8f3d24c257f21c25f90.json
lucylin   791236  222200  0  2025 ?        00:00:00 /home/lucylin/miniconda3/bin/python /home/lucylin/.vscode-server/extensions/ms-python.python-2025.12.0-linux-x64/python_files/lib/jedilsp/jedi/inference/compiled/subprocess/__main__.py /home/lucylin/.vscode-server/extensions/ms-python.python-2025.12.0-linux-x64/python_files/lib/jedilsp 3.9.21
kbaek     791594       1  0  2025 ?        00:02:35 /home/kbaek/miniconda3/bin/python -m ipykernel_launcher --f=/run/user/22249/jupyter/runtime/kernel-v3632dfe41d2a2a3d0e9e24913659a3bdab4c1233b.json
gmoreira  980039       1  0  2025 ?        00:00:00 /home/gmoreira/.env/bin/python -c from multiprocessing.resource_tracker import main;main(7)
gmoreira  980080       1  0  2025 ?        00:03:40 /home/gmoreira/.env/bin/python -c from multiprocessing.spawn import spawn_main; spawn_main(tracker_fd=8, pipe_handle=12) --multiprocessing-fork
danqingw 1009858       1  0  2025 ?        00:02:05 /home/danqingw/miniconda3/envs/paraspeechcaps/bin/python -m ipykernel_launcher --f=/run/user/2707837/jupyter/runtime/kernel-v3a3fe75070bb85b710b5f4a394eda2f4874e6cb69.json
danqingw 1024559       1  0  2025 ?        00:02:22 /home/danqingw/miniconda3/envs/paraspeechcaps/bin/python -m ipykernel_launcher --f=/run/user/2707837/jupyter/runtime/kernel-v3a91dc75279ee089ffa5cc2b8e187619d7983a1f2.json
gmoreira 1150838       1  0  2025 ?        00:00:00 /home/gmoreira/.env/bin/python -c from multiprocessing.resource_tracker import main;main(7)
gmoreira 1150879       1  0  2025 ?        00:03:58 /home/gmoreira/.env/bin/python -c from multiprocessing.spawn import spawn_main; spawn_main(tracker_fd=8, pipe_handle=12) --multiprocessing-fork
gmoreira 1302005       1  0 Feb07 ?        00:00:00 /home/gmoreira/.env312/bin/python -c from multiprocessing.resource_tracker import main;main(7)
gmoreira 1302011       1  0 Feb07 ?        00:00:56 /home/gmoreira/.env312/bin/python -c from multiprocessing.spawn import spawn_main; spawn_main(tracker_fd=8, pipe_handle=12) --multiprocessing-fork
gmoreira 1396113       1  0 Feb04 ?        00:00:00 /home/gmoreira/.env312/bin/python -c from multiprocessing.resource_tracker import main;main(7)
gmoreira 1396114       1  0 Feb04 ?        00:01:06 /home/gmoreira/.env312/bin/python -c from multiprocessing.spawn import spawn_main; spawn_main(tracker_fd=8, pipe_handle=12) --multiprocessing-fork
gmoreira 1403895       1  0  2025 ?        00:00:00 /home/gmoreira/.env/bin/python -c from multiprocessing.resource_tracker import main;main(7)
gmoreira 1403936       1  0  2025 ?        00:03:21 /home/gmoreira/.env/bin/python -c from multiprocessing.spawn import spawn_main; spawn_main(tracker_fd=8, pipe_handle=12) --multiprocessing-fork
arnavgoe 1546797       1  0  2025 ?        00:02:50 /home/arnavgoe/miniconda3/envs/em/bin/python -m ipykernel_launcher --f=/run/user/6001650/jupyter/runtime/kernel-v3db53e948a6388bed6d5eb7c6728b5dee1e8d1229.json
arnavgoe 1548799       1  0  2025 ?        00:02:11 /home/arnavgoe/miniconda3/envs/em/bin/python -m ipykernel_launcher --f=/run/user/6001650/jupyter/runtime/kernel-v3978e9dfb02bc72b61089ae9b6464ee5fab6407af.json
gmoreira 1649059       1  0 Jan07 ?        00:00:00 /home/gmoreira/.env/bin/python -c from multiprocessing.resource_tracker import main;main(7)
gmoreira 1649100       1  0 Jan07 ?        00:02:20 /home/gmoreira/.env/bin/python -c from multiprocessing.spawn import spawn_main; spawn_main(tracker_fd=8, pipe_handle=12) --multiprocessing-fork
lucylin  1755128  222200  0  2025 ?        00:00:00 /home/lucylin/miniconda3/bin/python /home/lucylin/.vscode-server/extensions/ms-python.python-2025.12.0-linux-x64/python_files/lib/jedilsp/jedi/inference/compiled/subprocess/__main__.py /home/lucylin/.vscode-server/extensions/ms-python.python-2025.12.0-linux-x64/python_files/lib/jedilsp 3.9.21
eyeo2    2002788       1  0  2025 ?        00:59:14 /home/eyeo2/anaconda3/bin/python /home/eyeo2/anaconda3/bin/tensorboard --logdir /home/eyeo2/workspace/SAND/results --port 6006 --host 0.0.0.0
kbaek    2054060       1  0  2025 ?        00:02:23 /home/kbaek/miniconda3/bin/python -m ipykernel_launcher --f=/run/user/22249/jupyter/runtime/kernel-v3c265950567a5f52f8db05e104aeea72da97ba306.json
gmoreira 2304496       1  0 Feb05 ?        00:00:00 /home/gmoreira/.env312/bin/python -c from multiprocessing.resource_tracker import main;main(7)
gmoreira 2304497       1  0 Feb05 ?        00:01:03 /home/gmoreira/.env312/bin/python -c from multiprocessing.spawn import spawn_main; spawn_main(tracker_fd=8, pipe_handle=12) --multiprocessing-fork
gmoreira 2363300       1  0 Jan01 ?        00:00:00 /home/gmoreira/.env/bin/python -c from multiprocessing.resource_tracker import main;main(7)
gmoreira 2363341       1  0 Jan01 ?        00:02:37 /home/gmoreira/.env/bin/python -c from multiprocessing.spawn import spawn_main; spawn_main(tracker_fd=8, pipe_handle=12) --multiprocessing-fork
eyeo2    2525600       1  0  2025 ?        00:47:42 /home/eyeo2/anaconda3/bin/python /home/eyeo2/anaconda3/bin/tensorboard --logdir /home/eyeo2/workspace/SAND/results --port 6007 --host 0.0.0.0
aarusha  2552251 1182867  0 09:27 pts/306  00:00:00 grep --color=auto python
gliu2    2567094       1  0  2025 ?        00:02:15 /home/gliu2/miniconda3/envs/jaxmarl/bin/python -m ipykernel_launcher --f=/run/user/2710105/jupyter/runtime/kernel-v3e5cb354e1f035746c3c09fffceffe185adc079c5.json
gmoreira 2619321       1  0 Jan20 ?        00:00:00 /home/gmoreira/.env/bin/python -c from multiprocessing.resource_tracker import main;main(7)
gmoreira 2619364       1  0 Jan20 ?        00:01:40 /home/gmoreira/.env/bin/python -c from multiprocessing.spawn import spawn_main; spawn_main(tracker_fd=8, pipe_handle=12) --multiprocessing-fork
eyeo2    2727008 2556966  0  2025 pts/16   01:18:26 /home/eyeo2/anaconda3/envs/analysis/bin/python /home/eyeo2/anaconda3/envs/analysis/bin/tensorboard --logdir /home/eyeo2/workspace/SAND/results
gmoreira 2920917       1  0 Feb05 ?        00:00:00 /home/gmoreira/.env312/bin/python -c from multiprocessing.resource_tracker import main;main(7)
gmoreira 2920918       1  0 Feb05 ?        00:01:05 /home/gmoreira/.env312/bin/python -c from multiprocessing.spawn import spawn_main; spawn_main(tracker_fd=8, pipe_handle=12) --multiprocessing-fork
gghosal  3090962       1  0  2025 ?        00:02:16 /home/gghosal/miniconda3/envs/toyunlearning_nanogpt/bin/python -m ipykernel_launcher --f=/run/user/24443/jupyter/runtime/kernel-v38e1f49d7fb013454fe76076c5b753daaf0da8231.json
gmoreira 3154480       1  0  2025 ?        00:00:00 /home/gmoreira/.env/bin/python -c from multiprocessing.resource_tracker import main;main(7)
gmoreira 3154521       1  0  2025 ?        00:03:46 /home/gmoreira/.env/bin/python -c from multiprocessing.spawn import spawn_main; spawn_main(tracker_fd=8, pipe_handle=12) --multiprocessing-fork
gmoreira 3196226       1  0  2025 ?        00:00:00 /home/gmoreira/.env/bin/python -c from multiprocessing.resource_tracker import main;main(7)
gmoreira 3196267       1  0  2025 ?        00:03:39 /home/gmoreira/.env/bin/python -c from multiprocessing.spawn import spawn_main; spawn_main(tracker_fd=8, pipe_handle=12) --multiprocessing-fork
bchugg   3197719 3197253  0 Feb22 ?        00:00:00 sh /home/bchugg/.cursor-server/bin/linux-x64/4ca9b38c6c97d4243bf0c61e51426667cb964bd0/bin/cursor-server --start-server --host=127.0.0.1 --port 0 --install-extension anyscalecompute.anyscale-workspaces --install-extension ms-python.python --install-extension ms-toolsai.jupyter-renderers --install-extension ms-toolsai.jupyter-keymap --install-extension ms-toolsai.jupyter --connection-token-file /run/user/2690882/cursor-remote-code.token.fa90dc4bf180788189ea692bf21e8e5c --telemetry-level off --enable-remote-auto-shutdown --accept-server-license-terms
bchugg   3197732 3197719  0 Feb22 ?        00:08:33 /home/bchugg/.cursor-server/bin/linux-x64/4ca9b38c6c97d4243bf0c61e51426667cb964bd0/node /home/bchugg/.cursor-server/bin/linux-x64/4ca9b38c6c97d4243bf0c61e51426667cb964bd0/out/server-main.js --start-server --host=127.0.0.1 --port 0 --install-extension anyscalecompute.anyscale-workspaces --install-extension ms-python.python --install-extension ms-toolsai.jupyter-renderers --install-extension ms-toolsai.jupyter-keymap --install-extension ms-toolsai.jupyter --connection-token-file /run/user/2690882/cursor-remote-code.token.fa90dc4bf180788189ea692bf21e8e5c --telemetry-level off --enable-remote-auto-shutdown --accept-server-license-terms
catheri4 3330512       1  0  2025 ?        00:04:03 /home/catheri4/google-cloud-sdk/platform/bundledpythonunix/bin/python3 /home/catheri4/google-cloud-sdk/platform/gsutil/gsutil -o GSUtil:default_project_id=cmu-gpu-cloud -m rm -rf gs://cmu-gpucloud-catheri4/outputs/muon/CPTModel/tulu/
gmoreira 3396811       1  0 Feb22 ?        00:00:00 /home/gmoreira/.env312/bin/python -c from multiprocessing.resource_tracker import main;main(7)
gmoreira 3396812       1  0 Feb22 ?        00:00:04 /home/gmoreira/.env312/bin/python -c from multiprocessing.spawn import spawn_main; spawn_main(tracker_fd=8, pipe_handle=12) --multiprocessing-fork
catheri4 3416898       1  0  2025 ?        00:03:06 /home/catheri4/google-cloud-sdk/platform/bundledpythonunix/bin/python3 /home/catheri4/google-cloud-sdk/platform/gsutil/gsutil -o GSUtil:default_project_id=cmu-gpu-cloud -m rm -rf gs://cmu-gpucloud-catheri4/datasets/tulu
catheri4 3418580       1  0  2025 ?        00:03:14 /home/catheri4/google-cloud-sdk/platform/bundledpythonunix/bin/python3 /home/catheri4/google-cloud-sdk/platform/gsutil/gsutil -o GSUtil:default_project_id=cmu-gpu-cloud -m rm -rf gs://cmu-gpucloud-catheri4/datasets/alpaca
catheri4 3420344       1  0  2025 ?        00:03:08 /home/catheri4/google-cloud-sdk/platform/bundledpythonunix/bin/python3 /home/catheri4/google-cloud-sdk/platform/gsutil/gsutil -o GSUtil:default_project_id=cmu-gpu-cloud -m rm -rf gs://cmu-gpucloud-catheri4/datasets/tatsu-lab_alpaca
catheri4 3422598       1  0  2025 ?        00:02:59 /home/catheri4/google-cloud-sdk/platform/bundledpythonunix/bin/python3 /home/catheri4/google-cloud-sdk/platform/gsutil/gsutil -o GSUtil:default_project_id=cmu-gpu-cloud -m rm -rf gs://cmu-gpucloud-catheri4/datasets/social_i_qa
catheri4 3424537       1  0  2025 ?        00:04:08 /home/catheri4/google-cloud-sdk/platform/bundledpythonunix/bin/python3 /home/catheri4/google-cloud-sdk/platform/gsutil/gsutil -o GSUtil:default_project_id=cmu-gpu-cloud -m rm -rf gs://cmu-gpucloud-catheri4/datasets/openai_gsm8k
catheri4 3426177       1  0  2025 ?        00:04:12 /home/catheri4/google-cloud-sdk/platform/bundledpythonunix/bin/python3 /home/catheri4/google-cloud-sdk/platform/gsutil/gsutil -o GSUtil:default_project_id=cmu-gpu-cloud -m rm -rf gs://cmu-gpucloud-catheri4/datasets/openai_gsm8k_main
catheri4 3428880       1  0  2025 ?        00:03:03 /home/catheri4/google-cloud-sdk/platform/bundledpythonunix/bin/python3 /home/catheri4/google-cloud-sdk/platform/gsutil/gsutil -o GSUtil:default_project_id=cmu-gpu-cloud -m rm -rf gs://cmu-gpucloud-catheri4/datasets/allenai_tulu-3-sft-mixture
catheri4 3430765       1  0  2025 ?        00:04:00 /home/catheri4/google-cloud-sdk/platform/bundledpythonunix/bin/python3 /home/catheri4/google-cloud-sdk/platform/gsutil/gsutil -o GSUtil:default_project_id=cmu-gpu-cloud -m rm -rf gs://cmu-gpucloud-catheri4/datasets/allenai_social_i_qa
gmoreira 3433164       1  0  2025 ?        00:00:00 /home/gmoreira/.env/bin/python -c from multiprocessing.resource_tracker import main;main(7)
gmoreira 3433205       1  0  2025 ?        00:03:19 /home/gmoreira/.env/bin/python -c from multiprocessing.spawn import spawn_main; spawn_main(tracker_fd=8, pipe_handle=12) --multiprocessing-fork
catheri4 3551834       1  0  2025 ?        00:04:00 /home/catheri4/google-cloud-sdk/platform/bundledpythonunix/bin/python3 /home/catheri4/google-cloud-sdk/platform/gsutil/gsutil -o GSUtil:default_project_id=cmu-gpu-cloud cp gs://cmu-gpucloud-catheri4/datasets/tatsu-lab_alpaca/train/input_ids.npy .
gliu2    3585316       1  0  2025 ?        00:02:19 /home/gliu2/miniconda3/envs/jaxmarl/bin/python -m ipykernel_launcher --f=/run/user/2710105/jupyter/runtime/kernel-v3a878ada9fd26c10c3754af6f919c320df8c1a546.json
gmoreira 3691951       1  0 Feb20 ?        00:00:00 /home/gmoreira/.env312/bin/python -c from multiprocessing.resource_tracker import main;main(7)
gmoreira 3691952       1  0 Feb20 ?        00:00:08 /home/gmoreira/.env312/bin/python -c from multiprocessing.spawn import spawn_main; spawn_main(tracker_fd=8, pipe_handle=12) --multiprocessing-fork
gmoreira 3983080       1  0 Feb10 ?        00:00:00 /home/gmoreira/.env312/bin/python -c from multiprocessing.resource_tracker import main;main(7)
gmoreira 3983081       1  0 Feb10 ?        00:00:47 /home/gmoreira/.env312/bin/python -c from multiprocessing.spawn import spawn_main; spawn_main(tracker_fd=8, pipe_handle=12) --multiprocessing-fork
#kernel
Interface        RX Pkts/Rate    TX Pkts/Rate    RX Data/Rate    TX Data/Rate  
                 RX Errs/Drop    TX Errs/Drop    RX Over/Rate    TX Coll/Rate  

Got it — the key thing in what you pasted is: you’re not actually looking at your Slurm job’s processes at all, so lsof/ifstat aren’t telling you what you think they are.

Here’s what’s happening and how to do it correctly.

1) ps -ef | grep python is from the login node, not your job node

That ps output lists random peoples’ ipykernels/tensorboards/etc. There’s no python process that looks like your HF download job.

That usually means one of these is true:

You’re on a login node (not the compute node running job 6422454).

Your job runs in a container/cgroup and you can’t see it from login node.

The job is running under a different executable (bash + python inside) and you’re not filtering for it.

But the big one: you ran lsof -p 6422454 using the Slurm job ID. lsof -p expects a PID, not a job id. So that command is invalid for what you want.

2) Why lsof -p 6422454 is wrong

6422454 is a Slurm JobID

lsof -p <...> needs an OS process id (PID like 12345)

So even if it prints something, it’s not “your job’s open files”.

3) ifstat tells you bandwidth of the node you ran it on

Your ifstat output just shows the header and no rates. That can happen if:

there’s no traffic (or you don’t have permission to see it),

or ifstat is installed but not capturing (interface name mismatch),

but most importantly: you’re probably running it on the wrong node anyway.

If your job is downloading, you want network stats on the job’s compute node.

4) Correct way to find the job’s node, then inspect the job’s PID(s)

Run these from the login node:

Find which node the job is running on:

squeue -j 6422454 -o "%.18i %.9P %.8T %.10M %.20R"

The last column will show something like babel-x5-32 or gpu123.

Then get a shell on the allocated node:

If your cluster allows:

srun --jobid=6422454 --pty bash

This is the cleanest because it drops you into the same allocation/cgroup.

If that doesn’t work, use the node name from squeue:

ssh <node-name>

(Less reliable if Slurm cgroups isolate processes.)

Now, on that node, find the job’s processes via Slurm (best option):

scontrol listpids 6422454

This prints the PIDs belonging to the job.

Then you can do:

# pick one PID (usually the top-level python) and:
ps -fp <PID>
lsof -p <PID> | head

That’s the correct chain: JobID → node → PIDs → lsof.

5) If you want “is it stuck?” checks that actually work

Once you’re on the job node / inside srun --jobid ...:

CPU usage:

top -p <PID>

If CPU is near 0% for long periods, it’s probably blocked on I/O/network.

Are there active network connections to HF/S3?

ss -tpn | grep <PID> | head

If you see established connections to huggingface.co / amazonaws.com, it’s still moving.

Is the HF cache growing?

du -sh ~/.cache/huggingface/datasets ~/.cache/huggingface/hub 2>/dev/null

Run it twice a few minutes apart. If size is unchanged for 30+ minutes, you’re likely stuck/backing off.

Is it writing a ton of small files to shared FS (painfully slow)?

iostat -x 1 5

(If installed.) High %util on shared FS mount is a classic cause.

6) The most likely diagnosis given “21 hours”

Given your earlier logs: “Getting files for 187802 image URLs” — this often means you’re about to download ~200k images individually. On shared HPC filesystems, that can be brutal: tons of tiny file creates + HTTP overhead + rate limits.

If you confirm (using the steps above) that:

network is low / intermittent, and

cache size barely changes,

then the fix is usually:

switch to streaming=True (no full download), or

download shards / metadata first, then parallelize image fetch with a dedicated downloader to local scratch, or

use DownloadConfig(num_proc=...) to increase parallelism (but beware HF rate limits).

If you paste just the output of:

squeue -j 6422454 -o "%.18i %.9P %.8T %.10M %.20R"
scontrol show job 6422454 | egrep "NodeList=|Command=|WorkDir=|StdOut=|StdErr="

I can tell you exactly which node to hop onto and the best next command to run on your cluster.

squeue -j 6422454 -o "%.18i %.9P %.8T %.10M %.20R"
             JOBID PARTITION    STATE       TIME     NODELIST(REASON)
           6422454       cpu  RUNNING   22:15:33          babel-x5-32
srun --jobid=6422454 --pty bash
aarusha@login2:~/molmo(base) [aarusha@babel-x5-32 molmo]$ scontrol listpids 6422454
PID      JOBID    STEPID   LOCALID GLOBALID
3786174  6422454  batch    0       0       
3786062  6422454  batch    -       -       
3786397  6422454  batch    -       -       
633869   6422454  batch    -       -       
633870   6422454  batch    -       -       
633871   6422454  batch    -       -       
633872   6422454  batch    -       -       
633873   6422454  batch    -       -       
633874   6422454  batch    -       -       
633875   6422454  batch    -       -       
633876   6422454  batch    -       -       
633877   6422454  batch    -       -       
633879   6422454  batch    -       -       
633881   6422454  batch    -       -       
633882   6422454  batch    -       -       
1079411  6422454  0        0       0       
1079406  6422454  0        -       -       
1079629  6422454  0        -       -       
-1       6422454  extern   0       0       
3786055  6422454  extern   -       -       
3786058  6422454  extern   -       -       
aarusha@login2:~/molmo(base) [aarusha@babel-x5-32 molmo]$ 

Perfect — now you’re actually inside the allocation on babel-x5-32, and scontrol listpids shows a very important clue:

You have a bunch of PIDs in the 600k range (633869–633882 etc.) that look like a process pool / worker fan-out (very common for Hugging Face datasets downloads with multiprocessing).

You also have a small set around 3.786M (3786055/58/62/74/97) which are likely Slurm wrapper / bash / python parent processes.

You have a main step STEPID 0 with PID 1079411 (and related 1079406, 1079629). That’s usually the “real” top-level process tree for your command.

Now we can answer: is it actually downloading, or stuck/backing off / thrashing filesystem?

1) Identify what each PID is (do this first)

Run:

ps -fp 1079411,1079406,1079629,3786174,3786062,3786397,3786055,3786058

Then pick one of the 6338xx worker PIDs and inspect:

ps -fp 633869
ps -fp 633870

What you’re looking for:

a python ... command that includes datasets, huggingface_hub, xet, download, etc.

or a parent bash running your script.

2) See if the job is actively doing network I/O

Once you find the main python PID (often 1079411, but confirm), do:

# show established TCP connections owned by the process
ss -tpn | grep 1079411 | head -n 30

If that shows nothing, check workers instead:

for p in 633869 633870 633871 633872 633873; do
  echo "=== $p ==="
  ss -tpn | grep $p | head -n 5
done

Interpretation:

If you see connections to huggingface.co, datasets-server.huggingface.co, amazonaws.com, etc. → it’s still actively talking to remote.

If you see no sockets for all relevant PIDs → it’s likely stuck in local I/O, deadlocked, or sleeping/backoff.

3) Check whether they’re sleeping vs running vs blocked

Run:

top -b -n 1 -p 1079411 | head -n 20
ps -o pid,stat,pcpu,pmem,wchan:30,cmd -p 1079411

Then sample a few worker PIDs:

ps -o pid,stat,pcpu,wchan:30,cmd -p 633869,633870,633871,633872,633873

Interpretation:

STAT like R = running, S = sleeping, D = uninterruptible sleep (often blocked on disk/network).

wchan tells you what it’s blocked on (e.g., futex_wait, nfs_*, tcp_*, do_sys_poll).

If you see lots of D and wchan is NFS-ish, you’re filesystem-bound (common when writing 200k tiny files).

4) Check if the HF cache is growing (this is the simplest “progress meter”)

Run twice, a couple minutes apart:

du -sh ~/.cache/huggingface/datasets ~/.cache/huggingface/hub 2>/dev/null

If it’s growing steadily, it’s working (just slow).
If it’s flat for a long time, it’s likely stuck or endlessly retrying/backing off.

5) Check the job log for “retries” / “429” / “timeout” (rate limits)

Inside your allocation:

# adjust filename if needed
tail -n 200 molmo-download-6422454.out | egrep -i "retry|429|rate|timeout|connection|error|exception" | tail -n 50

If you see repeated retry/backoff messages, that explains 22 hours.

What your PID list suggests (high-confidence guess)

Those many 6338xx processes strongly suggest you already have multiprocessing workers. If it’s still taking 22 hours, the bottleneck is usually:

shared filesystem metadata (writing hundreds of thousands of small files to a network home directory), or

rate limiting / retries against HF/S3, or

a deadlock / hung worker pool (workers exist but idle).

The checks above will distinguish these quickly.

If it’s the filesystem (most common on clusters)

You’ll see:

many processes in D state

wchan mentioning NFS / IO wait

network sockets mostly idle

HF cache size barely changing

Fix for next run:

set HF cache to node-local scratch before running:

export HF_HOME=/scratch/$USER/hf
export HF_DATASETS_CACHE=/scratch/$USER/hf/datasets
export TRANSFORMERS_CACHE=/scratch/$USER/hf/transformers
mkdir -p "$HF_DATASETS_CACHE" "$TRANSFORMERS_CACHE"

(or use whatever local disk path Babel provides)

This alone can turn “22 hours” into “1–3 hours” depending on bandwidth.

If you paste two command outputs, I can tell you exactly which case you’re in

Paste:

The output of:

ps -o pid,stat,pcpu,wchan:30,cmd -p 1079411,633869,633870,633871 | sed -e 's/  */ /g'

The output of:

du -sh ~/.cache/huggingface/datasets ~/.cache/huggingface/hub 2>/dev/null

With just those, I can tell you whether you’re (a) progressing slowly, (b) I/O-thrashing, or (c) stuck/retrying—and what the best immediate move is (leave it, kill & rerun with scratch cache, or reconfigure parallelism).

srun --jobid=6422454 --pty bash
aarusha@login2:~/molmo(base) [aarusha@babel-x5-32 molmo]$ scontrol listpids 6422454
PID      JOBID    STEPID   LOCALID GLOBALID
3786174  6422454  batch    0       0       
3786062  6422454  batch    -       -       
3786397  6422454  batch    -       -       
633869   6422454  batch    -       -       
633870   6422454  batch    -       -       
633871   6422454  batch    -       -       
633872   6422454  batch    -       -       
633873   6422454  batch    -       -       
633874   6422454  batch    -       -       
633875   6422454  batch    -       -       
633876   6422454  batch    -       -       
633877   6422454  batch    -       -       
633879   6422454  batch    -       -       
633881   6422454  batch    -       -       
633882   6422454  batch    -       -       
1079411  6422454  0        0       0       
1079406  6422454  0        -       -       
1079629  6422454  0        -       -       
-1       6422454  extern   0       0       
3786055  6422454  extern   -       -       
3786058  6422454  extern   -       -       
aarusha@login2:~/molmo(base) [aarushps -fp 1079411,1079406,1079629,3786174,3786062,3786397,3786055,3786058786397,3786055,3786058
UID          PID    PPID  C STIME TTY          TIME CMD
root     1079406       1  0 09:29 ?        00:00:00 slurmstepd: [6422454.0]
aarusha  1079411 1079406  0 09:29 pts/2    00:00:00 /usr/bin/bash
root     3786055       1  0 Feb22 ?        00:00:01 slurmstepd: [6422454.extern]
root     3786058 3786055  0 Feb22 ?        00:00:00 sleep 100000000
root     3786062       1  0 Feb22 ?        00:00:01 slurmstepd: [6422454.batch]
aarusha  3786174 3786062  0 Feb22 ?        00:00:00 /bin/bash /var/spool/slurmd/job6422454/slurm_script
aarusha  3786397 3786174  0 Feb22 ?        00:06:04 python3 scripts/download_data.py pixmo --n_procs 12
aarusha@login2:~/molmo(base) [aarush# show established TCP connections owned by the processs owned by the process
ss -tpn | grep 3786397 | head -n 30
CLOSE-WAIT 25     0               10.1.1.58:51342        3.171.139.16:443   users:(("python3",pid=3786397,fd=10))
CLOSE-WAIT 25     0               10.1.1.58:36020       16.182.72.248:443   users:(("python3",pid=3786397,fd=9)) 
CLOSE-WAIT 25     0               10.1.1.58:33984         3.168.73.38:443   users:(("python3",pid=3786397,fd=8)) 
aarusha@login2:~/molmo(base) [aarusha@babel-x5-32 molmo]$ 

Great, this output is very diagnostic.

What we now know

Your actual workload process is:

python3 scripts/download_data.py pixmo --n_procs 12 with PID 3786397

It’s being launched by the Slurm batch script (/var/spool/slurmd/job6422454/slurm_script).

The srun --jobid=... --pty bash shell you opened is not the main job process:

PID 1079411 is just your interactive bash inside the allocation.

That’s why it shows 0 CPU / 0 time — it’s just a shell.

The network state is suspicious:

All connections for PID 3786397 are in CLOSE-WAIT.

Example:

CLOSE-WAIT ... users:(("python3",pid=3786397,fd=10))
Why CLOSE-WAIT matters

CLOSE-WAIT means:

The remote side has closed the TCP connection, and

your process has not closed its end yet.

Seeing a couple of CLOSE-WAIT sockets briefly can be normal.
Seeing them persist (and especially in quantity) after 22 hours is often a sign of:

the Python process is leaking sockets / not closing responses (common with HTTP libs if responses aren’t fully consumed/closed), or

it’s stuck in a state where workers died / requests got interrupted and the parent is not cleaning up, or

a retry loop where connections are constantly being opened/closed but not cleaned up fast enough.

Given you only see 3 sockets here and all are CLOSE-WAIT, the top suspicion is: the process is not actively downloading anymore (or is badly wedged), because you’d expect some ESTAB sockets if it’s actively fetching a lot of content.

What to do next (in order)
1) Check whether the process is actually doing anything (CPU + state + wait channel)

Run:

ps -o pid,stat,pcpu,pmem,etime,wchan:30,cmd -p 3786397

Interpretation:

STAT=R with CPU > a few % → it’s running.

STAT=S with CPU ~0 → sleeping/idle (often stuck waiting).

STAT=D → blocked on I/O (filesystem or network).

wchan will often literally tell us: futex_wait, do_sys_poll, nfs_*, etc.

2) Inspect the worker PIDs (the 6338xx ones) to see if your “--n_procs 12” pool is alive

Pick a few and run:

ps -o pid,ppid,stat,pcpu,etime,wchan:30,cmd -p 633869,633870,633871,633872,633873

If those are your workers, their PPID should typically trace back to 3786397 (or to a multiprocessing supervisor).

If they’re all sleeping with 0 CPU for a long time, the pipeline is stalled.

3) See if it’s stuck on filesystem writes (super common on HPC)

Run:

# check whether HF cache is
aarusha@login2:~/molmo(base) [aarushps -o pid,stat,pcpu,pmem,etime,wchan:30,cmd -p 3786397chan:30,cmd -p 3786397
    PID STAT %CPU %MEM     ELAPSED WCHAN                          CMD
3786397 Sl    0.4  0.1    22:17:59 futex_wait_queue               python3 scripts/download_data.py pixmo --n_procs 12

This is the smoking gun:

3786397  STAT=Sl  %CPU=0.4  ELAPSED=22:17:59  WCHAN=futex_wait_queue
What that means

S = sleeping (not running on CPU)

l = multithreaded

futex_wait_queue = it’s blocked waiting on a futex (Linux userspace lock / condition variable)

In plain terms: the main Python process is mostly idle and waiting for other threads/processes to signal it. This is exactly what you see when:

worker processes are stuck/hung, or

workers died and the parent is waiting forever, or

a queue/join in multiprocessing is deadlocked, or

you’re stuck in a retry/backoff path where a worker is sleeping and parent is waiting.

Given the ss output showing only CLOSE-WAIT sockets, I’d bet it’s not actively downloading right now.

Next: check the worker PIDs (this will tell us which of the 4 cases it is)

Run:

ps -o pid,ppid,stat,pcpu,pmem,etime,wchan:30,cmd -p \
633869,633870,633871,633872,633873,633874,633875,633876,633877,633879,633881,633882

What to look for:

If many workers are D state with wchan like nfs_* / rpc_* / wait_on_page
→ you’re filesystem-bound (shared FS is killing you).

If workers are S state with wchan like futex_wait_queue / hrtimer_nanosleep / do_sys_poll
→ likely deadlock or they’re all idle waiting.

If workers have disappeared (ps shows “no such process”) but still listed in scontrol listpids
→ stale PID list / defunct children; parent may be waiting on join.

If workers show python doing HTTP and have active ESTAB sockets
→ it is working, but parent is waiting on a queue; then the bottleneck might be one slow worker.

Also do these two quick checks (they’re extremely informative)
A) Are there any active (ESTAB) sockets for the job at all?

Run:

ss -tpn | egrep "pid=3786397|pid=6338" | head -n 50

If you still only see CLOSE-WAIT and no ESTAB → network is effectively not active.

B) Is your HF cache growing anymore?

Run now and again 2–3 minutes later:

du -sh ~/.cache/huggingface/datasets ~/.cache/huggingface/hub 2>/dev/null

If unchanged → stuck.

If it’s stuck (high probability): what I’d do immediately

Given 22 hours + parent waiting on futex + CLOSE-WAIT sockets, the pragmatic move is:

Cancel the job (otherwise it can sit forever):

scancel 6422454

Rerun with node-local caching to avoid shared filesystem death and reduce stalls:

On Babel you likely have something like /scratch/$USER or $TMPDIR. Use whichever exists.

In your Slurm script, before running python:

export HF_HOME=/scratch/$USER/hf
export HF_DATASETS_CACHE=/scratch/$USER/hf/datasets
export TRANSFORMERS_CACHE=/scratch/$USER/hf/transformers
mkdir -p "$HF_DATASETS_CACHE" "$TRANSFORMERS_CACHE"

(Optional but often huge) reduce per-image file explosion:

If your script downloads images individually, consider switching to streaming / reading parquet metadata and only fetching needed images later, or using a parallel bulk downloader to scratch.

But before you kill it, do the worker ps output — that will tell us if it’s a deadlock vs filesystem vs just “one worker hung”.

Paste the output of the worker ps command and I’ll tell you the exact failure mode and the best rerun settings (including whether --n_procs 12 is too high/low for your environment).

aarusha@login2:~/molmo(base) [aarushps -o pid,ppid,stat,pcpu,pmem,etime,wchan:30,cmd -p \time,wchan:30,cmd -p \
633869,633870,633871,633872,633873,633874,633875,633876,633877,633879,633881,633882
    PID    PPID STAT %CPU %MEM     ELAPSED WCHAN                          CMD
 633869 3786397 S     3.1  0.1    04:13:38 do_poll.constprop.0            python3 scripts/download_data.py pixmo --n_procs 12
 633870 3786397 S     3.1  0.1    04:13:38 do_poll.constprop.0            python3 scripts/download_data.py pixmo --n_procs 12
 633871 3786397 S     3.3  0.1    04:13:38 do_poll.constprop.0            python3 scripts/download_data.py pixmo --n_procs 12
 633872 3786397 S     3.3  0.1    04:13:38 do_select                      python3 scripts/download_data.py pixmo --n_procs 12
 633873 3786397 S     0.9  0.1    04:13:38 do_poll.constprop.0            python3 scripts/download_data.py pixmo --n_procs 12
 633874 3786397 S     3.2  0.1    04:13:38 do_poll.constprop.0            python3 scripts/download_data.py pixmo --n_procs 12
 633875 3786397 S     3.0  0.1    04:13:38 do_select                      python3 scripts/download_data.py pixmo --n_procs 12
 633876 3786397 S     3.3  0.1    04:13:38 do_poll.constprop.0            python3 scripts/download_data.py pixmo --n_procs 12
 633877 3786397 S     3.3  0.1    04:13:38 do_select                      python3 scripts/download_data.py pixmo --n_procs 12
 633879 3786397 S     3.2  0.1    04:13:38 do_select                      python3 scripts/download_data.py pixmo --n_procs 12
 633881 3786397 S     1.9  0.1    04:13:38 do_select                      python3 scripts/download_data.py pixmo --n_procs 12
 633882 3786397 S     3.2  0.1    04:13:38 do_select                      python3 scripts/download_data.py pixmo --n_procs 12
aarusha@login2:~/molmo(base) [aarushss -tpn | egrep "pid=3786397|pid=6338" | head -n 50pid=6338" | head -n 50
ESTAB      0      0               10.1.1.58:38196      172.67.171.235:443   users:(("python3",pid=633870,fd=12)) 
CLOSE-WAIT 25     0               10.1.1.58:43396       205.196.81.33:443   users:(("python3",pid=633870,fd=30)) 
ESTAB      0      0               10.1.1.58:54646         13.33.71.61:443   users:(("python3",pid=633876,fd=10)) 
ESTAB      0      0               10.1.1.58:57514       23.215.177.51:443   users:(("python3",pid=633872,fd=27)) 
ESTAB      0      0               10.1.1.58:37374        35.201.70.94:443   users:(("python3",pid=633879,fd=10)) 
CLOSE-WAIT 25     0               10.1.1.58:47204        18.164.96.10:443   users:(("python3",pid=633872,fd=40)) 
CLOSE-WAIT 25     0               10.1.1.58:56674         192.0.78.24:443   users:(("python3",pid=633871,fd=33)) 
CLOSE-WAIT 1      0               10.1.1.58:35274        35.201.70.94:443   users:(("python3",pid=633872,fd=41)) 
CLOSE-WAIT 25     0               10.1.1.58:58846        104.26.5.193:443   users:(("python3",pid=633871,fd=10)) 
ESTAB      0      0               10.1.1.58:47414          23.185.0.3:443   users:(("python3",pid=633879,fd=12)) 
CLOSE-WAIT 25     0               10.1.1.58:51342        3.171.139.16:443   users:(("python3",pid=3786397,fd=10))
CLOSE-WAIT 25     0               10.1.1.58:33722        104.18.6.223:443   users:(("python3",pid=633875,fd=13)) 
ESTAB      0      0               10.1.1.58:34770        3.168.122.72:443   users:(("python3",pid=633871,fd=9))  
CLOSE-WAIT 25     0               10.1.1.58:53660       13.107.246.40:443   users:(("python3",pid=633872,fd=10)) 
CLOSE-WAIT 25     0               10.1.1.58:36020       16.182.72.248:443   users:(("python3",pid=3786397,fd=9)) 
ESTAB      0      0               10.1.1.58:56418     162.159.140.232:80    users:(("python3",pid=633871,fd=34)) 
ESTAB      0      0               10.1.1.58:33386       213.186.33.24:443   users:(("python3",pid=633870,fd=33)) 
CLOSE-WAIT 25     0               10.1.1.58:33984         3.168.73.38:443   users:(("python3",pid=3786397,fd=8)) 
CLOSE-WAIT 25     0               10.1.1.58:43404       205.196.81.33:443   users:(("python3",pid=633870,fd=31)) 
CLOSE-WAIT 25     0               10.1.1.58:38274         192.0.72.26:443   users:(("python3",pid=633871,fd=24)) 
CLOSE-WAIT 1      0               10.1.1.58:55976      76.223.105.230:80    users:(("python3",pid=633872,fd=12)) 
CLOSE-WAIT 25     0               10.1.1.58:47412         18.164.96.7:443   users:(("python3",pid=633879,fd=9))  
CLOSE-WAIT 25     0               10.1.1.58:33644      116.202.15.201:443   users:(("python3",pid=633882,fd=10)) 
ESTAB      0      0               10.1.1.58:39648      77.236.217.215:80    users:(("python3",pid=633873,fd=9))  
ESTAB      0      0               10.1.1.58:58932         13.33.71.61:443   users:(("python3",pid=633877,fd=9))  
CLOSE-WAIT 25     0               10.1.1.58:58402          23.185.0.1:443   users:(("python3",pid=633872,fd=9))  
CLOSE-WAIT 25     0               10.1.1.58:54456       13.107.213.40:443   users:(("python3",pid=633876,fd=9))  
CLOSE-WAIT 25     0               10.1.1.58:42626      108.138.128.62:443   users:(("python3",pid=633876,fd=12)) 
CLOSE-WAIT 1      0               10.1.1.58:51086        13.248.243.5:80    users:(("python3",pid=633872,fd=13)) 
ESTAB      0      0               10.1.1.58:33380       213.186.33.24:443   users:(("python3",pid=633870,fd=22)) 
ESTAB      0      0               10.1.1.58:49370      104.17.111.190:443   users:(("python3",pid=633875,fd=9))  
ESTAB      0      0               10.1.1.58:34744      77.236.217.215:443   users:(("python3",pid=633873,fd=10)) 
ESTAB      0      0               10.1.1.58:58856         13.33.71.61:443   users:(("python3",pid=633870,fd=13)) 

This is actually good news: it’s not deadlocked. It’s just spending almost all its time waiting on network sockets.

What your outputs say

Workers are alive and are the ones doing the work

Every worker PID (633869–633882) has PPID=3786397 and has nontrivial CPU time.

They’re in STAT=S (sleeping) but with wchan=do_poll/do_select.

do_poll/do_select means: “blocked waiting for sockets to become readable/writable” → classic network I/O wait, not filesystem.

There are active sockets

You have multiple ESTAB connections for workers (good).

You also have many CLOSE-WAIT sockets (bad-ish but not fatal): suggests the HTTP client isn’t closing promptly, but the presence of ESTAB means it’s still progressing.

Why the parent is in futex_wait

Parent (3786397) is basically a coordinator waiting for worker results / queue signals. That’s normal for multiprocessing.

So the picture is:

12 workers are doing lots of HTTP requests; they spend most of their time blocked in poll/select; total throughput is low; after 22 hours you’re still grinding through a huge URL list.

That’s consistent with downloading ~200k images one-by-one over HTTPS with rate limits + latency.

The real question: is it making progress, or just thrashing/retrying?

Two quick “progress truth” checks:

1) Is the cache / output directory still growing?

Run twice 2–3 minutes apart:

du -sh ~/.cache/huggingface/datasets ~/.cache/huggingface/hub 2>/dev/null

If you know where your script writes images, also:

du -sh <your_output_dir_for_pixmo_images>

If sizes are increasing: it’s just slow but working.
If flat: it’s stuck in retries/backoff loops.

2) Are workers receiving data (not just holding sockets)?

Look at per-process network bytes (very direct):

# requires /proc access (you have it)
for p in 633869 633870 633871 633872; do
  echo "== $p =="
  awk '{print $1,$2}' /proc/$p/net/dev | head -n 5
done

Crude, but if RX/TX counters move over time, you’re downloading.

Why it’s so slow (most likely)

A few things jump out:

Lots of distinct remote IPs/CDNs (Cloudflare, Akamai, AWS, random 80/443 endpoints). That often means:

many redirects,

variable latency,

occasional throttling,

connection churn → CLOSE-WAIT pileups.

HTTP keep-alive / connection reuse might be poor, causing tons of TCP handshakes.

Rate limiting: HF and CDNs can soft-throttle high parallel request volume.

12 procs is not crazy, but for some CDNs it can be “high enough to trigger throttling while still not being enough to be fast”.

What I would do now (actionable options)
Option A: If it’s progressing (cache size grows), let it finish but reduce pain for next time

For next run, do all downloads to node-local disk:

export HF_HOME=/scratch/$USER/hf
export HF_DATASETS_CACHE=/scratch/$USER/hf/datasets
export TRANSFORMERS_CACHE=/scratch/$USER/hf/transformers
mkdir -p "$HF_DATASETS_CACHE" "$TRANSFORMERS_CACHE"

Then after it finishes, copy results to your home/project storage.

This avoids shared filesystem overhead, but your current evidence points to network wait more than FS wait.

Option B: If it’s barely progressing, change strategy (recommended)

If your goal is training, you usually don’t want “download 200k JPEGs as separate files” on HPC.

Better patterns:

streaming=True and read examples without full download

download parquet shards (few large files) and decode lazily

if you must fetch images, use a dedicated bulk downloader (aria2c) with tuned concurrency and keep-alive, and save to scratch

Option C: Tune concurrency right now

Counterintuitively, sometimes lowering concurrency improves throughput because you get fewer throttles and fewer broken connections.

Try rerunning with:

--n_procs 4 or --n_procs 6

Or if you suspect underutilization and no throttling, try higher (16/24). But given CLOSE-WAIT churn, I’d try lower first.

One more high-signal check: are you rate-limited?

Search your logs for 429 / 5xx / retry:

tail -n 400 molmo-download-6422454.out | egrep -i "429|too many|rate|retry|backoff|timeout|5[0-9]{2}" | tail -n 80

If you see lots of those, that explains 22 hours and strongly argues for lowering --n_procs or using a different download method.

What I think is happening, in one sentence

Your job is alive and actively doing HTTPS I/O, but it’s latency/rate-limit bound fetching a massive number of small objects, which is why 22 hours is plausible.

Paste:

the du -sh ... output (twice, a few minutes apart, even just “before/after”), and

the log grep for 429/retry,

and I’ll tell you whether to: let it run, kill and rerun with fewer procs, or switch strategies entirely.

aarusha@login2:~/molmo(base) [aarusha@babel-x5-32 molmo]$ tail -n 400 molmo-download-6422454.out | egrep -i "429|too many|rate|retry|backoff|timeout|5[0-9]{2}" | tail -n 80                  tail -n 400 molmo-download-6422454.out | egrep -i "429|too many|rate|retry|backoff|timeout|5[0-9]{2}" | tail -n 80
2026-02-22 11:13:51.314	babel-x5-32:0	httpx:1025	INFO	HTTP Request: HEAD https://huggingface.co/api/resolve-cache/datasets/allenai/pixmo-docs/d887597bf4af2bc61a4210071a8cef898287e6fb/README.md "HTTP/1.1 200 OK"
2026-02-22 11:13:51.416	babel-x5-32:0	httpx:1025	INFO	HTTP Request: HEAD https://huggingface.co/datasets/allenai/pixmo-docs/resolve/d887597bf4af2bc61a4210071a8cef898287e6fb/pixmo-docs.py "HTTP/1.1 404 Not Found"
2026-02-22 11:13:51.568	babel-x5-32:0	httpx:1025	INFO	HTTP Request: GET https://huggingface.co/api/datasets/allenai/pixmo-docs/revision/d887597bf4af2bc61a4210071a8cef898287e6fb "HTTP/1.1 200 OK"
2026-02-22 11:13:51.601	babel-x5-32:0	httpx:1025	INFO	HTTP Request: HEAD https://huggingface.co/datasets/allenai/pixmo-docs/resolve/d887597bf4af2bc61a4210071a8cef898287e6fb/.huggingface.yaml "HTTP/1.1 404 Not Found"
2026-02-22 11:13:51.719	babel-x5-32:0	httpx:1025	INFO	HTTP Request: GET https://huggingface.co/api/datasets/allenai/pixmo-docs/tree/d887597bf4af2bc61a4210071a8cef898287e6fb/charts?recursive=true&expand=false "HTTP/1.1 200 OK"
2026-02-22 11:13:51.756	babel-x5-32:0	httpx:1025	INFO	HTTP Request: GET https://huggingface.co/api/datasets/allenai/pixmo-docs/tree/d887597bf4af2bc61a4210071a8cef898287e6fb?recursive=false&expand=false "HTTP/1.1 200 OK"
2026-02-22 11:13:51.795	babel-x5-32:0	httpx:1025	INFO	HTTP Request: HEAD https://huggingface.co/datasets/allenai/pixmo-docs/resolve/d887597bf4af2bc61a4210071a8cef898287e6fb/dataset_infos.json "HTTP/1.1 404 Not Found"
2026-02-22 11:13:51.835	babel-x5-32:0	httpx:1025	INFO	HTTP Request: GET https://huggingface.co/api/datasets/allenai/pixmo-docs/tree/d887597bf4af2bc61a4210071a8cef898287e6fb/other?recursive=true&expand=false "HTTP/1.1 200 OK"
2026-02-22 11:13:52.083	babel-x5-32:0	httpx:1025	INFO	HTTP Request: HEAD https://huggingface.co/api/resolve-cache/datasets/allenai/pixmo-docs/d887597bf4af2bc61a4210071a8cef898287e6fb/README.md "HTTP/1.1 200 OK"
2026-02-22 11:13:52.113	babel-x5-32:0	httpx:1025	INFO	HTTP Request: HEAD https://huggingface.co/datasets/allenai/pixmo-docs/resolve/d887597bf4af2bc61a4210071a8cef898287e6fb/pixmo-docs.py "HTTP/1.1 404 Not Found"
2026-02-22 11:13:52.169	babel-x5-32:0	httpx:1025	INFO	HTTP Request: HEAD https://huggingface.co/datasets/allenai/pixmo-docs/resolve/d887597bf4af2bc61a4210071a8cef898287e6fb/.huggingface.yaml "HTTP/1.1 404 Not Found"
2026-02-22 11:13:52.384	babel-x5-32:0	httpx:1025	INFO	HTTP Request: HEAD https://huggingface.co/datasets/allenai/pixmo-docs/resolve/d887597bf4af2bc61a4210071a8cef898287e6fb/dataset_infos.json "HTTP/1.1 404 Not Found"
2026-02-22 11:13:52.384	babel-x5-32:0	huggingface_hub.utils._http:779	WARNING	Warning: You are sending unauthenticated requests to the HF Hub. Please set a HF_TOKEN to enable higher rate limits and faster downloads.
2026-02-22 11:13:52.519	babel-x5-32:0	httpx:1025	INFO	HTTP Request: HEAD https://huggingface.co/datasets/allenai/pixmo-docs/resolve/main/README.md "HTTP/1.1 307 Temporary Redirect"
2026-02-22 11:13:52.536	babel-x5-32:0	httpx:1025	INFO	HTTP Request: HEAD https://huggingface.co/api/resolve-cache/datasets/allenai/pixmo-docs/d887597bf4af2bc61a4210071a8cef898287e6fb/README.md "HTTP/1.1 200 OK"
2026-02-22 11:13:52.570	babel-x5-32:0	httpx:1025	INFO	HTTP Request: HEAD https://huggingface.co/datasets/allenai/pixmo-docs/resolve/d887597bf4af2bc61a4210071a8cef898287e6fb/pixmo-docs.py "HTTP/1.1 404 Not Found"
2026-02-22 11:13:52.586	babel-x5-32:0	httpx:1025	INFO	HTTP Request: HEAD https://s3.amazonaws.com/datasets.huggingface.co/datasets/datasets/allenai/pixmo-docs/allenai/pixmo-docs.py "HTTP/1.1 404 Not Found"
2026-02-22 11:13:52.626	babel-x5-32:0	httpx:1025	INFO	HTTP Request: HEAD https://huggingface.co/datasets/allenai/pixmo-docs/resolve/d887597bf4af2bc61a4210071a8cef898287e6fb/.huggingface.yaml "HTTP/1.1 404 Not Found"
2026-02-22 11:13:52.710	babel-x5-32:0	httpx:1025	INFO	HTTP Request: HEAD https://huggingface.co/datasets/allenai/pixmo-docs/resolve/d887597bf4af2bc61a4210071a8cef898287e6fb/dataset_infos.json "HTTP/1.1 404 Not Found"
2026-02-22 11:13:52.752	babel-x5-32:0	httpx:1025	INFO	HTTP Request: GET https://huggingface.co/api/datasets/allenai/pixmo-docs/tree/d887597bf4af2bc61a4210071a8cef898287e6fb/diagrams?recursive=true&expand=false "HTTP/1.1 200 OK"
2026-02-22 11:13:52.873	babel-x5-32:0	httpx:1025	INFO	HTTP Request: HEAD https://huggingface.co/api/resolve-cache/datasets/allenai/pixmo-docs/d887597bf4af2bc61a4210071a8cef898287e6fb/README.md "HTTP/1.1 200 OK"
2026-02-22 11:13:52.905	babel-x5-32:0	httpx:1025	INFO	HTTP Request: HEAD https://huggingface.co/datasets/allenai/pixmo-docs/resolve/d887597bf4af2bc61a4210071a8cef898287e6fb/pixmo-docs.py "HTTP/1.1 404 Not Found"
2026-02-22 11:13:52.959	babel-x5-32:0	httpx:1025	INFO	HTTP Request: HEAD https://huggingface.co/datasets/allenai/pixmo-docs/resolve/d887597bf4af2bc61a4210071a8cef898287e6fb/.huggingface.yaml "HTTP/1.1 404 Not Found"
2026-02-22 11:13:53.043	babel-x5-32:0	httpx:1025	INFO	HTTP Request: HEAD https://huggingface.co/datasets/allenai/pixmo-docs/resolve/d887597bf4af2bc61a4210071a8cef898287e6fb/dataset_infos.json "HTTP/1.1 404 Not Found"
2026-02-22 11:13:53.081	babel-x5-32:0	httpx:1025	INFO	HTTP Request: GET https://huggingface.co/api/datasets/allenai/pixmo-docs/tree/d887597bf4af2bc61a4210071a8cef898287e6fb/tables?recursive=true&expand=false "HTTP/1.1 200 OK"
2026-02-22 11:13:53.512	babel-x5-32:0	httpx:1025	INFO	HTTP Request: GET https://huggingface.co/api/datasets/allenai/pixmo-points/tree/2b5c6931e790e00ae00d4a2857e5f95d88f09a66/data?recursive=true&expand=false "HTTP/1.1 200 OK"
2026-02-22 11:13:53.567	babel-x5-32:0	httpx:1025	INFO	HTTP Request: GET https://huggingface.co/api/datasets/allenai/pixmo-points/tree/2b5c6931e790e00ae00d4a2857e5f95d88f09a66?recursive=false&expand=false "HTTP/1.1 200 OK"
2026-02-23 05:15:15.417	babel-x5-32:0	root:175	INFO	Got images for 165103/228080 (72.39%) image URLs
2026-02-23 05:15:15.561	babel-x5-32:0	httpx:1025	INFO	HTTP Request: HEAD https://huggingface.co/datasets/allenai/pixmo-points-eval/resolve/main/README.md "HTTP/1.1 307 Temporary Redirect"
2026-02-23 05:19:23.381	babel-x5-32:0	root:75	INFO	Done with PixMoPoints in 65130.2 seconds
2026-02-23 05:19:23.490	babel-x5-32:0	httpx:1025	INFO	HTTP Request: HEAD https://huggingface.co/api/resolve-cache/datasets/allenai/pixmo-cap-qa/fd3ff4b2905455ab5edfd6d06039ea6027948521/README.md "HTTP/1.1 200 OK"
2026-02-23 05:19:23.531	babel-x5-32:0	httpx:1025	INFO	HTTP Request: GET https://huggingface.co/api/resolve-cache/datasets/allenai/pixmo-cap-qa/fd3ff4b2905455ab5edfd6d06039ea6027948521/README.md "HTTP/1.1 200 OK"
2026-02-23 05:19:23.608	babel-x5-32:0	httpx:1025	INFO	HTTP Request: HEAD https://huggingface.co/datasets/allenai/pixmo-cap-qa/resolve/fd3ff4b2905455ab5edfd6d06039ea6027948521/pixmo-cap-qa.py "HTTP/1.1 404 Not Found"
2026-02-23 05:19:23.736	babel-x5-32:0	httpx:1025	INFO	HTTP Request: GET https://huggingface.co/api/datasets/allenai/pixmo-cap-qa/revision/fd3ff4b2905455ab5edfd6d06039ea6027948521 "HTTP/1.1 200 OK"
2026-02-23 05:19:23.770	babel-x5-32:0	httpx:1025	INFO	HTTP Request: HEAD https://huggingface.co/datasets/allenai/pixmo-cap-qa/resolve/fd3ff4b2905455ab5edfd6d06039ea6027948521/.huggingface.yaml "HTTP/1.1 404 Not Found"
2026-02-23 05:19:24.011	babel-x5-32:0	httpx:1025	INFO	HTTP Request: GET https://huggingface.co/api/datasets/allenai/pixmo-cap-qa/tree/fd3ff4b2905455ab5edfd6d06039ea6027948521/data?recursive=true&expand=false "HTTP/1.1 200 OK"
2026-02-23 05:19:24.073	babel-x5-32:0	httpx:1025	INFO	HTTP Request: GET https://huggingface.co/api/datasets/allenai/pixmo-cap-qa/tree/fd3ff4b2905455ab5edfd6d06039ea6027948521?recursive=false&expand=false "HTTP/1.1 200 OK"
2026-02-23 05:19:24.110	babel-x5-32:0	httpx:1025	INFO	HTTP Request: HEAD https://huggingface.co/datasets/allenai/pixmo-cap-qa/resolve/fd3ff4b2905455ab5edfd6d06039ea6027948521/dataset_infos.json "HTTP/1.1 404 Not Found"
2026-02-23 05:19:24.157	babel-x5-32:0	httpx:1025	INFO	HTTP Request: HEAD https://huggingface.co/datasets/allenai/pixmo-cap-qa/resolve/fd3ff4b2905455ab5edfd6d06039ea6027948521/data/train-00000-of-00001.parquet "HTTP/1.1 302 Found"
2026-02-23 05:19:24.186	babel-x5-32:0	httpx:1025	INFO	HTTP Request: GET https://huggingface.co/api/datasets/allenai/pixmo-cap-qa/xet-read-token/fd3ff4b2905455ab5edfd6d06039ea6027948521 "HTTP/1.1 200 OK"
aarusha@login2:~/molmo(base) [aarusha@babel-x5-32 molmo]$ 

This log answers the “why is it taking forever?” pretty decisively.

1) You are being rate-limited because you’re unauthenticated

This line is the key:

WARNING Warning: You are sending unauthenticated requests to the HF Hub. Please set a HF_TOKEN to enable higher rate limits and faster downloads.

Even if you’re not seeing explicit 429 lines, HF will often slow you down / force you onto tighter limits when you’re not logged in. With 12 processes making tons of requests, you’ll hit those ceilings quickly and throughput collapses.

Fix: set an HF token.

On the node / in your Slurm script:

export HF_TOKEN=hf_...   # or HUGGINGFACE_HUB_TOKEN

(Depending on version, both work; I usually set both to be safe:)

export HF_TOKEN=hf_...
export HUGGINGFACE_HUB_TOKEN=$HF_TOKEN

If you don’t have one:

go to Hugging Face → Settings → Access Tokens → create a read token

paste it into your environment (ideally via a secure method, not hardcoded in the script if your cluster logs env).

2) It is making progress — it’s just slow

You have explicit progress:

Got images for 165103/228080 (72.39%) image URLs

And then:

Done with PixMoPoints in 65130.2 seconds

65130.2 seconds is ~18.1 hours. That matches your 22-hour job runtime pretty well (plus overhead and the next dataset starting).

So the job isn’t stuck; it’s just doing an enormous number of small downloads under constrained rate limits.

3) Why you see so many 404/307/302

That’s normal dataset resolution behavior (checking for optional files, redirects to S3/CDN, etc.) and not the problem.

The problem is: many requests + unauthenticated + parallelism = throttled throughput.

4) What I recommend you do right now

You have two reasonable choices:

Option A: Let this job finish (low effort)

It already finished PixMoPoints and started PixMoCap-QA. If you’re okay waiting, it will eventually complete.

But for future runs, you should absolutely set HF_TOKEN.

Option B: Cancel and rerun with token + better caching (faster overall)

If you still have a lot left and don’t want another 10–20 hours, cancel and restart properly:

Cancel:

scancel 6422454

Rerun with:

HF token enabled

cache on local scratch (optional but often helps)

possibly tweak --n_procs

Example (in your Slurm script):

export HF_TOKEN=hf_xxx
export HUGGINGFACE_HUB_TOKEN=$HF_TOKEN

# if you have node-local scratch:
export HF_HOME=/scratch/$USER/hf
export HF_DATASETS_CACHE=$HF_HOME/datasets
export TRANSFORMERS_CACHE=$HF_HOME/transformers
mkdir -p "$HF_DATASETS_CACHE" "$TRANSFORMERS_CACHE"

Then run your script.

5) About --n_procs 12

With a token, 12 might be fine. Without a token, 12 basically guarantees you’ll slam into limits.

Even with a token, if you see lots of connection churn (CLOSE-WAIT) and low throughput, sometimes 6–8 can outperform 12 because you get fewer throttles and fewer retries.

A pragmatic approach:

With token: start with --n_procs 8

If bandwidth is clearly underutilized, increase to 12 or 16.

6) Quick check: how much is left?

Since you logged PixMoPoints completion and it moved to pixmo-cap-qa, you can estimate remaining time by looking for similar “Got images for X/Y” lines for the new dataset.

Try:

grep -E "Got images for|Done with" molmo-download-6422454.out | tail -n 50

That will show where you are in each dataset.

If you tell me how you’re currently supplying secrets on Babel (env vars, ~/.bashrc, module, etc.), I’ll give you the safest way to inject HF_TOKEN into Slurm without it ending up in logs.

heres the token, give me what to copy paste

hf_***REDACTED***

First — revoke that token immediately.

You just pasted a live Hugging Face access token into a public chat.
Go to:

Hugging Face → Settings → Access Tokens → Delete that token now

Then create a new read-only token.

Now here’s exactly what to copy-paste safely on Babel.

Option 1 (quick fix for current shell / test run)

After you generate a new token:

export HF_TOKEN="hf_NEW_TOKEN_HERE"
export HUGGINGFACE_HUB_TOKEN="$HF_TOKEN"

Then run your script.

Option 2 (recommended for Slurm job script)

In your Slurm script before the python command:

# --- Hugging Face auth ---
export HF_TOKEN="hf_NEW_TOKEN_HERE"
export HUGGINGFACE_HUB_TOKEN="$HF_TOKEN"

# Optional but recommended: local scratch caching
export HF_HOME="/scratch/$USER/hf"
export HF_DATASETS_CACHE="$HF_HOME/datasets"
export TRANSFORMERS_CACHE="$HF_HOME/transformers"
mkdir -p "$HF_DATASETS_CACHE" "$TRANSFORMERS_CACHE"

Then your normal:

python3 scripts/download_data.py pixmo --n_procs 8

(I’d start with 8 instead of 12 after authentication.)

Even cleaner (avoids token in Slurm logs)

Instead of putting the token in the script:

On the node (once):

huggingface-cli login

Paste your new token when prompted.

This stores it in:

~/.cache/huggingface/token

Then you don’t need to export anything in the job script at all.

That’s the cleanest HPC setup.

After you revoke + regenerate

Tell me:

whether you want to let the current job finish, or

kill and rerun with token + scratch cache

Given your progress (~72% done on first dataset), I can estimate remaining runtime more precisely.

aarusha@login2:~/molmo(base) [aarusha@babel-x5-32 molmo]$ huggingface-cli login
Usage: hf [OPTIONS] COMMAND [ARGS]...
Try 'hf --help' for help.

Error: No such command 'login'.
aarusha@login2:~/molmo(base) [aarusha@babel-x5-32 molmo]$ 

Good — this just means you have the new Hugging Face CLI (hf), not the old huggingface-cli.

Use this instead:

hf auth login

It will prompt:

Enter your token:

Paste your new read-only token (not the leaked one).

If it succeeds, you’ll see something like:

Login successful
Token saved to ...

That’s it. After that:

You do not need to export HF_TOKEN in your Slurm script.

All HF downloads will automatically use your authenticated rate limits.

If hf auth login fails for any reason, fallback method:

echo "hf_NEW_TOKEN_HERE" > ~/.cache/huggingface/token
chmod 600 ~/.cache/huggingface/token

But try hf auth login first.

Once you’ve logged in, I’d recommend:

Cancel the current job:

scancel 6422454

Rerun with:

python3 scripts/download_data.py pixmo --n_procs 8

You should see noticeably fewer connection stalls and much higher throughput.

Let me know once you log in and I’ll help you sanity-check that authentication is actually being used (there’s a very quick way to verify).

5455ab5edfd6d06039ea6027948521/.huggingface.yaml "HTTP/1.1 404 Not Found"
2026-02-23 05:19:24.011	babel-x5-32:0	httpx:1025	INFO	HTTP Request: GET https://huggingface.co/api/datasets/allenai/pixmo-cap-qa/tree/fd3ff4b2905455ab5edfd6d06039ea6027948521/data?recursive=true&expand=false "HTTP/1.1 200 OK"
2026-02-23 05:19:24.073	babel-x5-32:0	httpx:1025	INFO	HTTP Request: GET https://huggingface.co/api/datasets/allenai/pixmo-cap-qa/tree/fd3ff4b2905455ab5edfd6d06039ea6027948521?recursive=false&expand=false "HTTP/1.1 200 OK"
2026-02-23 05:19:24.110	babel-x5-32:0	httpx:1025	INFO	HTTP Request: HEAD https://huggingface.co/datasets/allenai/pixmo-cap-qa/resolve/fd3ff4b2905455ab5edfd6d06039ea6027948521/dataset_infos.json "HTTP/1.1 404 Not Found"
2026-02-23 05:19:24.157	babel-x5-32:0	httpx:1025	INFO	HTTP Request: HEAD https://huggingface.co/datasets/allenai/pixmo-cap-qa/resolve/fd3ff4b2905455ab5edfd6d06039ea6027948521/data/train-00000-of-00001.parquet "HTTP/1.1 302 Found"
2026-02-23 05:19:24.186	babel-x5-32:0	httpx:1025	INFO	HTTP Request: GET https://huggingface.co/api/datasets/allenai/pixmo-cap-qa/xet-read-token/fd3ff4b2905455ab5edfd6d06039ea6027948521 "HTTP/1.1 200 OK"
aarusha@login2:~/molmo(base) [aarushexport HF_TOKEN="hf_***REDACTED***"yAWPOCKmcLlXGxLBsbsZN"
export HUGGINGFACE_HUB_TOKEN="$HF_TOKEN"
aarusha@login2:~/molmo(base) [aarusha@babel-x5-32 molmo]$ huggingface-cli login
Usage: hf [OPTIONS] COMMAND [ARGS]...
Try 'hf --help' for help.

Error: No such command 'login'.
aarusha@login2:~/molmo(base) [aarusha@babel-x5-32 molmo]$ hf auth login

User is already logged in.
aarusha@login2:~/molmo(base) [aarusha@babel-x5-32 molmo]$ 
aarusha@login2:~/molmo(base) [aarusha@babel-x5-32 molmo]$ 

Two important things here:

You pasted a new token in chat again. Revoke it too.

Hugging Face → Settings → Access Tokens → delete the leaked token right now.

Create a fresh read-only token.

Don’t paste it here again.

hf auth login saying “User is already logged in.” means your machine already has a token saved (in your home directory cache), and the CLI will use it. So you likely don’t need export HF_TOKEN=... at all.

What you should copy-paste now (safe, no token)
A) Verify what account/token the node will use

Run:

hf auth whoami

If it prints your HF username, you’re good.

If it errors, then you’re not actually logged in (despite the earlier message), and we’ll fix it without exposing tokens.

B) Make sure your running Slurm job is using authentication

Your current job was started before you logged in/exported, so it may still be using unauthenticated requests.

Fastest and cleanest: restart the job so the token is definitely picked up by the processes.

Copy-paste:

scancel 6422454

Then re-submit your job the same way you originally did (whatever sbatch ... command you used).

C) If you want to keep it running without restarting (less reliable)

You can’t inject env vars into an already-running Slurm job in a clean way. The worker processes already inherited their environment at launch. So the right move is restart.

Also: you had a small typo in your export line

I see:

export HF_TOKEN="hf_***REDACTED***"yAWPOCKmcLlXGxLBsbsZN"

That has extra trailing text after the closing quote, which would break the command. (Another reason to avoid exporting tokens manually.)

Best practice on Babel (no token in scripts, no token in shell history)

Log in once (interactive, token never echoed):

hf auth login

Verify:

hf auth whoami

Submit jobs normally (no token exports).

The token is stored under your home directory (typically ~/.cache/huggingface/), with permissions so only you can read it.

One more thing: remove the leaked tokens from your shell history

On the node where you ran export HF_TOKEN=..., do:

history | tail -n 20

Then remove the specific lines (bash):

history -d <LINE_NUMBER>
history -w

(If you want, paste the history | tail -n 20 output with the token characters replaced by REDACTED and I’ll tell you exactly which line numbers to delete.)

Minimal next step

Copy-paste these two commands:

hf auth whoami
scancel 6422454

Then resubmit.