# vLLM token monitoring

Scrapes each vLLM server's built-in Prometheus metrics (`/metrics`) and shows
token usage in the dashboard ("vLLM Token Usage" section). No change to Kong.

## Check a vLLM server exposes metrics
```bash
curl -s http://<vllm-ip>:8000/metrics | grep -E 'vllm:(prompt|generation)_tokens_total'
```
If those lines appear, you're good. (vLLM exposes metrics by default unless
started with `--disable-log-stats`.)

## Add machines (no restart needed)
Edit `vllm-targets.yml` — Prometheus reloads it within ~30s.

Simple list:
```yaml
- targets: ['10.0.0.11:8000', '10.0.0.12:8000', '10.0.0.13:8000']
  labels:
    group: 'vllm'
```

Friendly per-machine names (recommended — shown in the dashboard):
```yaml
- targets: ['10.0.0.11:8000']
  labels: { node: 'vllm-01', group: 'vllm' }
- targets: ['10.0.0.12:8000']
  labels: { node: 'vllm-02', group: 'vllm' }
```

Verify they're being scraped:
```bash
curl -s http://localhost:9090/api/v1/targets | \
  python3 -c "import sys,json;[print(t['scrapeUrl'],t['health']) for t in json.load(sys.stdin)['data']['activeTargets'] if t['labels'].get('job')=='vllm']"
```

## Metrics used
- `vllm:prompt_tokens_total`     — input tokens (counter)
- `vllm:generation_tokens_total` — output tokens (counter)

Dashboard panels: token rate by model / by machine, and range tables for tokens
by model and prompt/completion tokens by machine.

> This measures tokens per MODEL and per MACHINE. To attribute tokens to a
> CONSUMER (which client), Kong's AI Gateway (ai-proxy + ai_metrics) is required,
> which needs Kong 3.11+ — a separate, larger change.
