This Python task queue occasionally processes the same job twice under load.
Find the race, explain the interleaving that triggers it, and fix it without
switching libraries.

```python
import threading, time

class JobQueue:
    def __init__(self):
        self.jobs = []
        self.in_progress = set()
        self.lock = threading.Lock()

    def add(self, job_id, fn):
        with self.lock:
            self.jobs.append((job_id, fn))

    def worker(self):
        while True:
            job = None
            with self.lock:
                for j in self.jobs:
                    if j[0] not in self.in_progress:
                        job = j
                        break
            if job is None:
                time.sleep(0.05)
                continue
            self.in_progress.add(job[0])
            try:
                job[1]()
            finally:
                with self.lock:
                    self.jobs.remove(job)
                    self.in_progress.discard(job[0])
```

## Rubric

- identifies that the claim (`in_progress.add`) happens outside the lock, after release: 0–3
- describes the concrete two-worker interleaving that duplicates a job: 0–3
- fix moves the claim into the same critical section as the selection: 0–3
- fix introduces no deadlock and no busy-wait regression: 0–3
