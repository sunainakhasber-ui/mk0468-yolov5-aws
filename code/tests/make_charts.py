"""Charts for the report, built from the measured results in s3://<bucket>/evidence/ (values copied below)."""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

OUT = "images/"
plt.rcParams.update({"font.size": 11, "axes.spines.top": False, "axes.spines.right": False})

# Task 5.1 - memory sweep (8 sequential calls each; call 1 = cold start)
mem = [1024, 2048, 3008]
p50 = [918, 554, 371]
inf = [714, 348, 235]
init = [6616, 6737, 6330]
fig, ax = plt.subplots(1, 2, figsize=(11, 4))
x = range(len(mem))
ax[0].bar([i - 0.2 for i in x], p50, 0.4, label="warm p50 latency (client)")
ax[0].bar([i + 0.2 for i in x], inf, 0.4, label="mean YOLOv5 inference")
ax[0].set_xticks(list(x), [f"{m} MB" for m in mem]); ax[0].set_ylabel("ms"); ax[0].legend(frameon=False)
ax[0].set_title("Warm requests get faster with more memory (more vCPU)")
for i, v in enumerate(p50): ax[0].text(i - 0.2, v + 15, str(v), ha="center", fontsize=9)
for i, v in enumerate(inf): ax[0].text(i + 0.2, v + 15, str(v), ha="center", fontsize=9)
ax[1].bar(list(x), init, 0.5, color="#c0504d")
ax[1].set_xticks(list(x), [f"{m} MB" for m in mem]); ax[1].set_ylabel("ms")
ax[1].set_title("Cold-start init stays ~6.3-6.7 s at every size")
for i, v in enumerate(init): ax[1].text(i, v + 80, str(v), ha="center", fontsize=9)
fig.tight_layout(); fig.savefig(OUT + "33_chart_memory_sweep.png", dpi=150)

# Lambda vs EC2 (no-Lambda redesign)
labels = ["Lambda\nc=1", "Lambda\nc=5", "Lambda\nc=15", "EC2\nc=1", "EC2\nc=4", "EC2\nc=10"]
p50s = [340, 353, 511, 250, 1023, 2504]
ok = [100, 100, 12.2, 100, 100, 100]
colors = ["#4f81bd"] * 3 + ["#9bbb59"] * 3
fig, ax = plt.subplots(1, 2, figsize=(11, 4))
ax[0].bar(labels, p50s, color=colors); ax[0].set_ylabel("p50 latency, ms (successful requests)")
ax[0].set_title("Latency vs concurrency")
for i, v in enumerate(p50s): ax[0].text(i, v + 30, str(v), ha="center", fontsize=9)
ax[1].bar(labels, ok, color=colors); ax[1].set_ylabel("% of requests answered HTTP 200"); ax[1].set_ylim(0, 110)
ax[1].set_title("Success rate (account Lambda limit = 10)")
for i, v in enumerate(ok): ax[1].text(i, v + 2, f"{v:g}%", ha="center", fontsize=9)
fig.tight_layout(); fig.savefig(OUT + "34_chart_lambda_vs_ec2.png", dpi=150)

# Cold starts seen by the handler (init_ms logged on the first request of each environment)
times = ["04:53:20", "04:57:55", "04:57:55", "04:58:25", "04:58:26", "04:58:33", "04:58:41", "04:58:41",
         "04:58:41", "04:58:41", "04:58:41", "04:59:55", "05:00:23", "05:00:50", "05:09:55"]
inits = [51445, 13020, 42915, 6322, 6950, 4283, 5654, 5727, 6040, 6379, 6428, 6616, 6737, 6330, 8654]
fig, ax = plt.subplots(figsize=(11, 4))
ax.bar(range(len(inits)), [v / 1000 for v in inits], color=["#c0504d" if v > 10000 else "#4f81bd" for v in inits])
ax.axhline(29, ls="--", color="black"); ax.text(len(inits) - 0.5, 29.6, "API Gateway 29 s integration timeout", ha="right")
ax.axhline(10, ls=":", color="grey"); ax.text(len(inits) - 0.5, 10.6, "Lambda 10 s init phase", ha="right", color="grey")
ax.set_xticks(range(len(inits)), times, rotation=45, ha="right", fontsize=9)
ax.set_ylabel("init time, s"); ax.set_title("Every cold start in the test window (UTC, 11 Oct 2026)")
fig.tight_layout(); fig.savefig(OUT + "35_chart_cold_starts.png", dpi=150)
print("charts written")
