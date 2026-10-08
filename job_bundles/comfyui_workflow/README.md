# ComfyUI workflow

This job bundle runs a [ComfyUI](https://github.com/Comfy-Org/ComfyUI) workflow headlessly on
AWS Deadline Cloud GPU workers, with one task per seed.

```
comfyui_workflow/
├── README.md
├── template.yaml
└── workflows/
    └── sd15_txt2img_api.json   # Default workflow: Stable Diffusion 1.5 text to image
```

## How it works

1. **The job environment** runs once per session, before the session's first task:
   - It downloads any models listed in `ModelDownloads` that aren't in the model cache yet,
     and verifies them against their SHA-256 checksums.
   - It writes an `extra_model_paths.yaml` that points ComfyUI at the cache.
   - It starts the ComfyUI server on a free local port, with the base directory in the session
     directory and the output directory set to `OutputDir`, and waits until the server answers.
2. **Each task** loads the workflow and sets every `seed` and `noise_seed` input to the task's
   seed. It adds `_seed<N>` to each `filename_prefix` so that tasks don't overwrite each other's
   outputs. It then submits the workflow to the local ComfyUI API, waits for it to finish, and
   prints the server output and the output files. Tasks in the same session reuse the running
   server, so they don't load models again.
3. **When the session ends**, the job environment stops the server and prints its last output.
   Job attachments collects the files in `OutputDir`.

## Prerequisites

- **The `comfyui` conda package** in an S3 conda channel that your queue can read. Build it
  from the [ComfyUI conda recipe](../../conda_recipes/comfyui/README.md).
- **A conda queue environment** whose `CondaChannels` lists that channel before `conda-forge`,
  for example
  `s3://amzn-s3-demo-bucket/Conda/Default conda-forge`. The job sets `CondaPackages` to
  `comfyui`. Python and its base libraries come from conda-forge.
- **A Linux GPU fleet** whose runtime driver is `latest` or `grid:r580`. The package uses
  PyTorch CUDA 13.0 wheels, which need driver r580 or newer. The job requires one GPU.
- **Outbound internet access** on the workers, to download the default model from Hugging Face.

## Submitting the job

From the `job_bundles` directory, submit the default workflow:

```
deadline bundle submit comfyui_workflow
```

To render more seeds, or your own workflow:

```
deadline bundle submit comfyui_workflow \
    -p WorkflowFile=/path/to/my_workflow_api.json \
    -p Seeds=1-16
```

You can also use `deadline bundle gui-submit comfyui_workflow` to set the parameters in the
submitter.

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `WorkflowFile` | `workflows/sd15_txt2img_api.json` | A workflow in ComfyUI's API format. |
| `Seeds` | `1-4` | The seeds to run, one task per seed. |
| `OutputDir` | `./output` | Where ComfyUI writes the outputs of Save nodes. |
| `ModelDownloads` | Stable Diffusion 1.5 (fp16) | Models to download into the cache, as space-separated `FOLDER/FILE=URL#sha256=HEX` entries. |
| `ModelCacheDir` | empty | The model cache directory on the worker. Empty uses the fleet's persistent volume, or `/var/tmp`. |
| `ExtraModelPathsConfig` | empty | An `extra_model_paths.yaml` on the worker, for model folders on shared storage. |
| `ComfyUIArgs` | empty | Extra arguments for the ComfyUI server, such as `--lowvram`. |
| `ServerStartTimeout` | `600` | Seconds to wait for the server to start. |

## Using your own workflow

1. In ComfyUI, build the workflow and save it with **Workflow > Export (API)**. The job rejects
   workflows saved in the regular UI format, because the API needs the API format.
2. Make sure that every model the workflow loads is either listed in `ModelDownloads` with the
   file name the workflow uses, or available through `ExtraModelPathsConfig`. For example, a
   workflow that also uses a LoRA could set:

   ```
   -p ModelDownloads="checkpoints/model.safetensors=https://... loras/style.safetensors=https://..."
   ```
3. The workflow must have at least one Save node, such as **SaveImage**. Otherwise the task
   fails because it produced no outputs.

Custom nodes aren't supported. The `comfyui` package doesn't include any, and installing them
at job time with pip would change the shared, cached conda environment.

## Models and caching

Each worker downloads a model only once. The job environment keeps models in
`$DEADLINE_PERSISTENT_MOUNT/comfyui-models` when the fleet has a
[persistent volume](https://docs.aws.amazon.com/deadline-cloud/latest/developerguide/smf-persistent-storage-dev.html).
That cache survives worker replacement. Without a persistent volume, it uses
`/var/tmp/comfyui-models` on the root volume, which lasts only as long as the worker. Don't put
the cache under `/tmp`: on Linux service-managed fleet workers, `/tmp` is a RAM-backed tmpfs.

For models on shared storage, such as Amazon FSx, write an `extra_model_paths.yaml` that points
at them and pass its path on the worker with `ExtraModelPathsConfig`. See
`$COMFYUI_LOCATION/extra_model_paths.yaml.example` in the `comfyui` package for the format.

## Testing on a CPU worker

To check the job without a GPU, remove the `amount.worker.gpu` host requirement from
`template.yaml`, and submit with `-p ComfyUIArgs=--cpu` and `-p Seeds=1`. Stable Diffusion 1.5
takes several minutes per image on a CPU.

## License

ComfyUI is distributed under the GPL-3.0 license. The default model,
[Stable Diffusion 1.5](https://huggingface.co/Comfy-Org/stable-diffusion-v1-5-archive), is
distributed under the CreativeML OpenRAIL-M license, which restricts some uses. Review the
license of every model you use.
