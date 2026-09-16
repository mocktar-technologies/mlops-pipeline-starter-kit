"""Shared contracts between the training pipeline and the serving path.

This package is copied into both container images. Nothing in it may import
torch, onnxruntime, pandas or boto3: it has to be importable from the serving
image, which contains none of those beyond ONNX Runtime, and from the training
image, which contains all of them. Keeping it dependency-free is what allows one
definition of the feature contract to be shared instead of copied.
"""
