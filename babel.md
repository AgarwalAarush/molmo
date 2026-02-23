# BABEL HPC Cluster — consolidated notes (for AI ingestion)

Generated: 2026-02-21T21:39:14.884667+00:00

This document is a **single Markdown bundle** of the BABEL wiki content you pasted into chat, plus relevant onboarding details from the uploaded PDF walk-through (see citations in chat response).  
It is intended to be handed to another AI so it can answer questions about “Babel” without needing access to the private wiki.

---

## 1. What is BABEL?

Babel is a high-performance computing (HPC) cluster for research / scientific compute. The wiki emphasizes:

- Architecture + specs (not fully included in the pasted text)
- Job submission guidelines
- Available software
- Best practices
- Support + communication channels

---

## 2. Getting started

### 2.1 Account requests

- Use the **Account Requests form** to request an account or request changes to an existing account.
- For account changes (groups, default shell, disk quota increases), use the **User Change Request** form.

### 2.2 Community / support

- Slack channel: **#babel-babble**
  - Ask questions, share insights
  - For admins: tag **@help-babel**
  - If needed, DM for privacy

---

## 3. Logging in (SSH)

### 3.1 Basic login command

```bash
ssh <username>@login.babel.cs.cmu.edu
```

- Credentials: use your Andrew ID + password (SCS credentials “have no power here” per the page).

### 3.2 Round-robin login nodes

There are **4 login nodes** behind round-robin DNS. You may land on any login node.  
If your `tmux` session is active on a different node, SSH directly to that login node:

```bash
ssh login2
```

### 3.3 Passwordless login (SSH keys)

Generate key:

```bash
ssh-keygen -t ed25519 -C "[$(whoami)@$(uname -n)-$(date -I)]"
```

Copy public key to cluster (uses Andrew password):

```bash
ssh-copy-id -i ${HOME}/.ssh/id_ed25519.pub <username>@<mycluster>
```

Windows alternative (from PowerShell in `.ssh` folder):

```powershell
type .\id_ed25519.pub | ssh <username>@<mycluster> "cat >> .ssh/authorized_keys"
```

Optional `~/.ssh/config` snippet:

```sshconfig
Host <mycluster>
  HostName <mycluster's hostname>
  User <username>
  IdentityFile ${HOME}/.ssh/id_ed25519
```

Login then becomes:

```bash
ssh mycluster
```

### 3.4 Connecting to a compute node (when you already have a running job)

```bash
ssh -J babel babel-X-XX
```

(Use `-J` / ProxyJump.)

### 3.5 Why is there an SSH keypair in my home directory?

The wiki says keys/fingerprints are pre-created so scripts can SSH between nodes without hanging on unknown host fingerprints, and to avoid password prompts when hopping to nodes where you have jobs running.

### 3.6 Troubleshooting: Windows “Corrupted MAC on input” (VSCode SSH)

If you see:

```
Corrupted MAC on input.
ssh_dispatch_run_fatal: Connection to ... port 22: message authentication code incorrect
```

Add ciphers/MACs to your local `~/.ssh/config`:

```sshconfig
Host babel babel-login
  HostName babel.lti.cs.cmu.edu
  Ciphers aes128-ctr,aes192-ctr,aes256-ctr
  MACs hmac-sha2-256,hmac-sha2-512,hmac-sha1
  User <USERNAME>
  ForwardAgent yes
  # Optional if using a key:
  # IdentityFile C:/Users/<USERNAME>/.ssh/<private_ssh_key_name>
```

---

## 4. Shell configuration

- To set/change your login + compute node shell, submit via the **Change Request Form**.
- If the desired shell isn’t in the dropdown, add it in notes.

---

## 5. Filesystem

### 5.1 Default user provisioned storage

- `/home/<username>`  
  - Capacity: **100 GB**
  - Mounted on **all nodes**
- `/data/user_data/<username>`  
  - Capacity: **500 GB**
  - Available **only on compute nodes with active jobs**

### 5.2 Additional shared paths on compute nodes

- `/data/datasets` — community datasets
- `/data/models` — community models
- `/scratch` — local SSD/NVMe
  - When >65% full, data older than 28 days is automatically expunged
- `/compute/<node_name>` — each node’s `/scratch` exported to all other nodes

### 5.3 AutoFS (“on-demand” mounts)

The wiki emphasizes that `home`, `user_data`, `datasets`, `models`, and `compute` mounts are network directories mounted via **AutoFS**.

Implication: higher-level directories can look empty until you reference (“stat”) the full path. Example pattern:

```bash
ls /compute          # may look empty
ls /compute/<node>   # triggers mount; shows that node's exported /scratch
```

---

## 6. Submitting jobs (Slurm)

### 6.1 Scheduler

- Babel uses **Slurm 24.05.1**.

### 6.2 Two main modes

- Interactive: typically via `salloc` then `srun`, for direct interaction.
- Batch: via `sbatch` for queued jobs.

### 6.3 Partitions overview (from pasted page)

#### debug
- Purpose: quick, short jobs for testing/debugging.
- Max time: 12 hours
- Default time: 1 hour
- Max GPUs: 2
- Max CPUs: 64
- QoS: `debug_qos`
- Limitation: no array jobs

#### general
- Purpose: general, standard computing tasks.
- Max time: 2 days
- Default time: 6 hours
- Max GPUs: 8
- Max CPUs: 128
- QoS: `normal`
- Limitations: no interactive sessions; `sbatch` only

#### preempt
- Purpose: long-running jobs that can be preempted for higher-priority tasks.
- Max time: 31 days
- Default time: 3 hours
- Max GPUs: 24
- Max CPUs: 256
- QoS: `preempt_qos`
- Limitations: no interactive sessions; `sbatch` only

#### cpu
- Purpose: CPU-only computing tasks.
- Max time: 2 days
- Default time: 6 hours
- Max GPUs: 0
- Max CPUs: 128
- QoS: `cpu_qos`
- Limitations: no interactive sessions; `sbatch` only

#### array
- Purpose: array jobs for parallel task execution.
- Max time: 12 days
- Default time: 6 hours
- Max GPUs: 8
- Max CPUs: 256
- QoS: `array_qos`
- Limitations: no interactive sessions; `sbatch` only

### 6.4 Partition/QoS table (as pasted)

```
Name        MaxTRESPU      MaxJobsPU  MaxSubmitPU  MaxTRES    MinTRES      Preempt
normal      gres/gpu=8     10         50           cpu=128    gres/gpu=1    array_qos,preempt_qos
preempt_qos gres/gpu=24    24         100          cpu=256    gres/gpu=1
debug_qos   gres/gpu=2     10         12           cpu=64                   preempt_qos
cpu_qos     gres/gpu=0     10         50           cpu=128                  preempt_qos
array_qos   gres/gpu=8     100        10000        cpu=256                  preempt_qos
```

### 6.5 Inspecting partitions and QoS

Partitions:

```bash
scontrol show part
scontrol show part <partition_name>
```

QoS for your account:

```bash
sacctmgr show user $USER withassoc format=User,Account,DefaultQOS,QOS%4
```

### 6.6 Common Slurm commands mentioned

- Run / launch: `srun`, `sbatch`
- Cancel: `scancel`
- History: `sacct`
- Cluster view: `sinfo`, `squeue`, `sstat`
- Resource utilization: `sstat`, `seff` (mentioned elsewhere)

### 6.7 sbatch minimal example (generic)

```bash
#!/bin/bash
#SBATCH --job-name=myjob
#SBATCH --output=myjob.out
#SBATCH --error=myjob.err
#SBATCH --partition=general
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=1
#SBATCH --time=1:00:00

echo "Hello, World!"
```

Submit:

```bash
sbatch myjob.sh
```

### 6.8 srun interactive example (generic)

```bash
srun -n 4 ./my_program
```

### 6.9 Array jobs example

```bash
#!/bin/bash
#SBATCH --job-name=array_job
#SBATCH --output=outputs/job_%A_%a.out
#SBATCH --error=errors/job_%A_%a.err
#SBATCH --partition=array
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=1
#SBATCH --time=1:00:00
#SBATCH --array=0-9

echo "Running task $SLURM_ARRAY_TASK_ID"
python my_script.py --task_id=$SLURM_ARRAY_TASK_ID
```

Submit and inspect:

```bash
sbatch array_job.sh
squeue --user=$USER --array
```

Limit concurrent tasks:

```bash
#SBATCH --array=0-9%2
```

### 6.10 Preemption + checkpointing pattern (generic)

Key directives and idea:

- `#SBATCH --requeue`
- `#SBATCH --signal=B:USR1@60` (signal 60 seconds before preemption)
- Use `trap` in script to checkpoint on `USR1`
- Resume from checkpoint when job restarts

---

## 7. Monitoring (web tools)

These require campus wired network, CMU-Secure, or CMU VPN.

- Ganglia: per-node load and I/O utilization
- Vejo: CPU/GPU/disk utilization (live utilization, not Slurm allocations)

Links (as pasted):
- Ganglia: `http://babel-cluster.lti.cs.cmu.edu/ganglia/`  
- Vejo: `http://babel-cluster.lti.cs.cmu.edu/vejo/`

---

## 8. HPC software list (as pasted)

### Containers
- `apptainer` (formerly singularity)

### Editors
- `emacs`, `vim`

### Shells
- `bash`, `zsh`

### Monitoring
- `atop`, `htop`, `top`

### Terminal multiplexers
- `screen`, `tmux`

### Version control
- `git`

---

## 9. Tips & Tricks index (as pasted)

The wiki has a “Tips & Tricks” hub linking to many articles, including:
- Filesystem, AutoFS, login node limits
- Slurm job management/efficiency/arrays/submission from Python
- Port forwarding
- VSCode
- Hugging Face
- Environment modules
- Monitoring (Ganglia / Vejo)
- Training material
- More

(Only the index and a handful of subpages were included in your pasted text.)

---

## 10. HPC terminology (high-level)

### 10.1 Cluster components (as described)

- Login node: user entrypoint; typically only home mounted
- Head/control node:
  - Ansible control
  - Slurm controller
  - Slurm database (may be colocated)
- Compute nodes: CPU/GPU resources + local scratch + network mounts
- NAS: network attached storage for shared data

### 10.2 AutoFS reminder

AutoFS mounts are on-demand; you may need to reference full paths to trigger mounts.

### 10.3 Scratch + /compute export pattern

Use local `/scratch` for large/frequent I/O; it’s exported cluster-wide via `/compute/<node_name>`.

Cleanup expectation:
- scratch is temporary
- if scratch hits high usage, data older than ~28 days may be deleted automatically (the pasted pages mention thresholds like 65%/85% depending on context)

---

## 11. Hugging Face on Babel

### 11.1 Storage locations

- Shared HF cache: `/data/hf_cache/`
  - Shared models and datasets
  - Accessible to users in `hpcgroup`
- Personal `$HOME`: `/home/<username>` (100 GB)
  - Good for small config/token files
- Personal data: `/data/user_data/<username>` (compute nodes only)
  - Use for larger personal HF cache / artifacts

### 11.2 Environment variables (recommended setup)

```bash
export HF_HOME=/data/user_data/<username>/.hf_cache
export HF_HUB_CACHE=/data/hf_cache/hub
export HF_DATASETS_CACHE=/data/hf_cache/datasets
export HF_HUB_OFFLINE=1  # optional
```

### 11.3 Permissions note (as pasted)

- `/data/hf_cache/` uses ACLs:
  - dirs 770, files 660
  - owned by initial user + group `hpcgroup`
- Ensure group membership via:

```bash
groups
```

---

## 12. Extra practical notes from the PDF walk-through

These are operational “how to” notes and examples that complement the wiki.

### 12.1 Logging in

```bash
ssh [andrewid]@babel.lti.cs.cmu.edu
```

### 12.2 Conda / environment setup

Example:

```bash
conda create -n myenv python=3.9
conda activate myenv
```

### 12.3 Interactive compute node (examples)

The PDF shows interactive `srun` examples and notes that a previous form “no longer works” as of a dated update in the slides.

Example “new command” pattern shown:

```bash
srun --time=24:00:00 --gres=gpu:1 --mem=32G --partition=debug --pty bash -i -l
```

It lists example GPU type strings (case sensitive) seen in the environment:
`1080Ti, A6000, 2080Ti, 8000, v100, A100_80GB, 6000Ada, 3090, A100_40GB, L40`.

### 12.4 Batch job skeleton (example)

The PDF includes a typical sbatch header:

```bash
#!/bin/bash
#SBATCH --job-name=rmt-5
#SBATCH --output=rmt-5.out
#SBATCH --error=rmt-5.err
#SBATCH --partition=general
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=64G
#SBATCH --time=6:00:00
#SBATCH --gres=gpu:A6000:1
# Your job commands go here
```

### 12.5 Checking cluster and job status

Examples shown include:

- Partition/node status:
  - `sinfo` with formatted output
  - `scontrol show nodes | grep A6000 -A 10`
- On-node GPU status:
  - `nvidia-smi`
  - `python /opt/cluster_tools/babel_contrib/tir_tool/gpu.py`
- Job status:
  - `top`
  - `squeue ... | grep [andrewid]`
- Cancelling jobs:
  - `scancel <jobid>`
  - bulk-cancel patterns

### 12.6 Jupyter via SSH port forwarding (pattern)

Run remotely:

```bash
jupyter lab --no-browser --port=8080
# or:
jupyter notebook --no-browser --port=8080
```

Forward locally:

```bash
ssh -L 8080:localhost:8080 babel-4-23
```

The PDF includes an example `~/.ssh/config` using `ProxyJump` through `babel`.

### 12.7 Data transfer

- `scp` example:

```bash
scp ./Desktop/random.py [andrewid]@babel.lti.cs.cmu.edu:~/
```

- Tools mentioned: VSCode remote folder, Xftp (Windows), Termius
- GitHub can be used for sync

### 12.8 Misc useful commands

- Clear terminal: `Ctrl+L`
- `chmod +x job.sh`
- Modules examples: `module avail`, `module load cuda-10.2`, `module load gcc-5.4.0`

---

## 13. Open questions / gaps

Your pasted text does **not** include:
- Full hardware inventory (GPU counts by type, node models, network fabric)
- Precise login node limits (there is a linked page for “Login Node Resource Limits”)
- Full policy pages (data retention, quotas, fairshare specifics, etc.)
- Full “Tips & Tricks” subpages (only the index and a few pages were pasted)

If you paste those pages too (or export the wiki subtree), I can append them into a bigger single Markdown bundle.

---
