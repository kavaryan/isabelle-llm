# KCL CREATE HPC Documentation Notes

Checked on 2026-05-20.

## Main Documentation

- CREATE HPC access: https://docs.er.kcl.ac.uk/CREATE/access/
- Running jobs with Slurm: https://docs.er.kcl.ac.uk/CREATE/running_jobs/
- Compute nodes and partitions: https://docs.er.kcl.ac.uk/CREATE/compute_nodes/
- Scheduler policy: https://docs.er.kcl.ac.uk/CREATE/scheduler_policy/
- GPU jobs: https://docs.er.kcl.ac.uk/CREATE/running_jobs_gpu/
- Multiple-node / MPI jobs: https://docs.er.kcl.ac.uk/CREATE/running_jobs_mpi/
- Long partitions: https://docs.er.kcl.ac.uk/CREATE/long_partition/
- Storage: https://docs.er.kcl.ac.uk/CREATE/storage/
- Modules/software environments: https://docs.er.kcl.ac.uk/CREATE/software/modules/
- Account and project access: https://docs.er.kcl.ac.uk/CREATE/requesting_access/

## Access

CREATE HPC is reached through SSH at `hpc.create.kcl.ac.uk`. KCL notes that this endpoint redirects to login nodes `erc-hpc-login3.hpc.er.kcl.ac.uk` or `erc-hpc-login4.hpc.er.kcl.ac.uk`; both should have equivalent configuration and software.

Local SSH config already has:

```sshconfig
Host create
    HostName hpc.create.kcl.ac.uk
    User k21191796
    PubkeyAuthentication yes
    IdentityFile ~/.ssh/create_hpc_rsa
    MACs hmac-sha2-256
```

## Slurm Basics

CREATE uses Slurm for job scheduling. Jobs can be submitted with command-line flags, for example `sbatch -p cpu --job-name hello job.sh`, or by putting `#SBATCH` directives at the top of the job script.

Useful directives for a simple CPU job:

```bash
#SBATCH --partition=cpu
#SBATCH --job-name=cpu_test
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=1G
#SBATCH --time=00:05:00
#SBATCH --output=/scratch/users/%u/%x-%j.out
#SBATCH --error=/scratch/users/%u/%x-%j.err
```

CREATE's documented default resources are 1 CPU core, 1 GB memory, and 24 hours runtime. The docs recommend requesting realistic time, memory, and CPU requirements so the scheduler can place jobs efficiently.

## Partitions And Cluster Parts

General-use partitions listed in the compute-node documentation:

| Partition | Nodes | CPU cores | GPUs | Access |
| --- | ---: | ---: | ---: | --- |
| `cpu` | 33 | 4224 | 0 | Open to all CREATE HPC users |
| `gpu` | 19 | 856 | 52 | Open to all CREATE HPC users |
| `long_cpu` | 5 | 640 | 0 | As-needed approval |
| `long_gpu` | 2 in compute-node table; long-partition page describes 3 nodes | 136 in compute-node table; long-partition page describes 400 cores | 6 in compute-node table; long-partition page describes 16 GPUs | As-needed approval |
| `interruptible_cpu` | 73 | 4672 | 0 | Open, lower priority, may be cancelled |

Departmental/faculty partitions listed in the compute-node documentation:

| Partition | Nodes | CPU cores | GPUs | Group restriction |
| --- | ---: | ---: | ---: | --- |
| `nmes_gpu` | 8 | 576 | 32 | `er_dpt_nmes` |
| `mathematics_cpu` | 2 | 256 | 0 | `er_dpt_mathematics` |
| `biomed_a30_gpu` | 2 | 96 | 16 | `er_grp_biomed_hpc` |
| `biomed_a100_gpu` | 4 | 512 | 32 | `er_grp_biomed_hpc` |

Standard public node specifications include 128-core CPU nodes with 1024 GB memory in the `cpu` partition, and GPU nodes with 36 CPU cores, 4 NVIDIA A100 40 GB GPUs with NVLink, and 512 GB memory in the `gpu` partition.

## Scheduler Policy

The `cpu` and `gpu` partitions are open to all CREATE HPC users. Current documented limits include:

- 48 hour maximum runtime on `cpu` and `gpu`.
- 700 concurrent CPU cores per user.
- 8 concurrent A100 GPUs per user.

Interruptible partitions use unused private capacity. These jobs have lower priority and may be cancelled when private partition owners need the resources.

## Long Partitions

The `long_cpu` and `long_gpu` partitions are for jobs that cannot finish within the regular 48 hour limit and require approval. The long-partition page documents:

- `long_cpu`: 5 compute nodes, 640 CPU cores, no GPUs, 7 day maximum runtime.
- `long_gpu`: 3 compute nodes, 400 CPU cores, 16 GPUs, 10 day maximum runtime.

The docs advise testing shorter jobs on the regular `cpu` or `gpu` partitions first, setting realistic `#SBATCH --time` values, and monitoring resource use.

## GPU Jobs

GPU jobs require `--gres=gpu` and should use a GPU partition such as `gpu` or `interruptible_gpu`, depending on access and intended use. CUDA-enabled jobs normally need `module load cuda`. Public GPU jobs can request up to 8 GPUs according to the GPU jobs page.

## Multiple-Node / MPI Jobs

Multiple-node jobs must use software that supports MPI or another distributed execution model. The docs describe `--nodes`, `--ntasks`, and `--ntasks-per-node`, for example:

- `--nodes=2 --ntasks=16` requests 16 cores across 2 compute nodes.
- `--nodes=2` requests all available cores on 2 compute nodes.
- `--ntasks=16` requests 16 cores across available compute nodes.
- `--nodes=2 --ntasks-per-node=16` requests 16 cores on each of 2 nodes.

## Storage

Documented storage locations:

| Storage | Mount point | Capacity | Mounted on | Use |
| --- | --- | --- | --- | --- |
| Home | `/users` | 39 TiB | Login and compute | Code, software, configuration, low-I/O files |
| Scratch | `/scratch` | 1.4 PiB | Login and compute | Job input/output, large data, high-bandwidth/low-latency I/O |

Important notes:

- `/scratch` is not backed up.
- User accounts are currently allocated 50 GiB under `/users` and 200 GiB under `/scratch/users`.
- Personal scratch path is `/scratch/users/<user id>`.
- Project scratch path is `/scratch/prj/<project name>`.

## Modules

CREATE uses environment modules. The docs recommend including required `module load ...` statements in job scripts. Useful commands:

```bash
ml spider python
module load <package>/<version>
module list
module purge
```

## Simple CPU Test Chosen Here

For a harmless smoke test, use the regular `cpu` partition with a short runtime and small memory request. The accompanying `cpu_test.sbatch` prints Slurm metadata, checks CPU information, runs a tiny Python calculation, and exits.

## vLLM / CUDA Troubleshooting Note

Public searches did not show a KCL-specific vLLM incident for the `libcudart.so.12` failure. The relevant CREATE documentation is still the GPU jobs and modules documentation:

- GPU jobs should request GPUs with `--gres=gpu` and load CUDA with `module load cuda`.
- CREATE modules are expected to modify environment variables such as `PATH` and `LD_LIBRARY_PATH`, and KCL recommends putting explicit `module load ...` statements in job scripts.
- No `vllm` module was available from `module avail vllm` or `module spider vllm` on CREATE, so vLLM has to be installed in a user environment.
- Current upstream vLLM installation docs say the default NVIDIA CUDA wheel is built for a newer CUDA stack, so unpinned `pip install vllm` can choose a wheel that is too new for CREATE's installed NVIDIA driver.

Observed on CREATE, 2026-05-21:

- The A100 node reported NVIDIA driver `535.288.01` and CUDA driver capability `12.2` via `nvidia-smi`.
- Installing unpinned latest vLLM pulled a newer CUDA/PyTorch stack that required a newer NVIDIA driver and failed with `The NVIDIA driver on your system is too old`.
- Pinning `vllm==0.8.5` and `torch==2.6.0+cu118` avoided the newer driver requirement, but vLLM still needed CUDA 12 runtime libraries for its own extensions.
- Loading `cuda/12.2.1-gcc-13.2.0` set `CUDA_HOME`, but `libcudart.so.12` was still not found until the job explicitly exported:

```bash
module load cuda/12.2.1-gcc-13.2.0
export LD_LIBRARY_PATH="$CUDA_HOME/lib64:${LD_LIBRARY_PATH:-}"
```

The working pattern for the local vLLM evaluation job is therefore:

1. Request one A100 on the `gpu` partition.
2. Load the explicit CUDA 12.2.1 module.
3. Add `$CUDA_HOME/lib64` to `LD_LIBRARY_PATH`.
4. Pin vLLM/PyTorch instead of installing the newest available wheel.
