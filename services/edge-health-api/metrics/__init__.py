"""Prometheus text adapter for the existing edge health API."""

from .prometheus import render_metrics

__all__ = ["render_metrics"]
