"""Where the models run: Apple GPU (Metal) on a Mac, an NVIDIA GPU if present, otherwise the CPU."""


def best_device() -> str:
    import torch

    if torch.backends.mps.is_available():
        return "mps"
    if torch.cuda.is_available():
        return "cuda"
    return "cpu"
