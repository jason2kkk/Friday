// 功能：提供 Friday 后台 Work 的最小运行时，用于验证异步 Agent 任务从提交到完成的主干流程。
// 职责：定义 Work 状态机、事件记录、幂等提交、取消与 Mock Agent 执行器，并维护可查询的内存任务状态。
// 边界：当前实现不访问外部文件、应用或账号，不持久化任务，也不执行发送、删除等真实副作用。

import { randomUUID } from "node:crypto";

export class WorkValidationError extends Error {}
export class WorkNotFoundError extends Error {}

export class InMemoryWorkStore {
  constructor({ maximumRecords = 100 } = {}) {
    this.maximumRecords = maximumRecords;
    this.records = new Map();
    this.workIDBySubmissionKey = new Map();
  }

  findBySubmissionKey(submissionKey) {
    const workID = this.workIDBySubmissionKey.get(submissionKey);
    return workID ? this.records.get(workID) || null : null;
  }

  get(workID) {
    return this.records.get(workID) || null;
  }

  save(record) {
    this.records.set(record.id, record);
    this.workIDBySubmissionKey.set(record.submission_key, record.id);
    this.pruneIfNeeded();
    return record;
  }

  pruneIfNeeded() {
    if (this.records.size <= this.maximumRecords) return;
    const terminal = [...this.records.values()]
      .filter(record => isTerminalWorkState(record.state))
      .sort((left, right) => left.updated_at.localeCompare(right.updated_at));
    while (this.records.size > this.maximumRecords && terminal.length > 0) {
      const record = terminal.shift();
      this.records.delete(record.id);
      this.workIDBySubmissionKey.delete(record.submission_key);
    }
  }
}

export class MockReadOnlyAgentExecutor {
  constructor({ delayMilliseconds = 900 } = {}) {
    this.delayMilliseconds = delayMilliseconds;
  }

  async execute(work, { signal } = {}) {
    await abortableDelay(this.delayMilliseconds, signal);
    return {
      summary: "Agent 主干已完成一次只读验证。",
      detail: `后台 Work 已独立接收目标“${work.objective}”。本次没有访问或修改任何外部内容。`
    };
  }
}

export class WorkRuntime {
  constructor({
    store = new InMemoryWorkStore(),
    executor = new MockReadOnlyAgentExecutor(),
    now = () => new Date()
  } = {}) {
    this.store = store;
    this.executor = executor;
    this.now = now;
    this.executions = new Map();
  }

  submit({ objective, submissionKey, source = "model_derived" }) {
    const normalizedObjective = normalizeObjective(objective);
    const normalizedSubmissionKey = normalizeSubmissionKey(submissionKey);
    const existing = this.store.findBySubmissionKey(normalizedSubmissionKey);
    if (existing) return existing;

    const timestamp = this.now().toISOString();
    const record = {
      id: `work_${randomUUID().replaceAll("-", "")}`,
      submission_key: normalizedSubmissionKey,
      objective: normalizedObjective,
      objective_source: source === "final_transcript" ? source : "model_derived",
      executor: "mock_read_only",
      state: "queued",
      public_activity: "等待执行",
      result: null,
      error: null,
      created_at: timestamp,
      updated_at: timestamp
    };
    this.store.save(record);
    this.start(record.id);
    return record;
  }

  get(workID) {
    const record = this.store.get(normalizeWorkID(workID));
    if (!record) throw new WorkNotFoundError("Work not found.");
    return record;
  }

  cancel(workID) {
    const record = this.get(workID);
    if (isTerminalWorkState(record.state)) return record;

    this.executions.get(record.id)?.abort();
    return this.update(record.id, {
      state: "cancelled",
      public_activity: "已取消",
      error: null
    });
  }

  start(workID) {
    const controller = new AbortController();
    this.executions.set(workID, controller);
    queueMicrotask(async () => {
      const initial = this.store.get(workID);
      if (!initial || initial.state !== "queued") return;
      const running = this.update(workID, {
        state: "running",
        public_activity: "正在进行只读验证"
      });
      try {
        const result = await this.executor.execute(running, {
          signal: controller.signal
        });
        const current = this.store.get(workID);
        if (!current || current.state === "cancelled") return;
        this.update(workID, {
          state: "completed",
          public_activity: "已完成",
          result,
          error: null
        });
      } catch (error) {
        const current = this.store.get(workID);
        if (!current || current.state === "cancelled") return;
        if (error?.name === "AbortError") {
          this.update(workID, {
            state: "cancelled",
            public_activity: "已取消",
            error: null
          });
        } else {
          this.update(workID, {
            state: "failed",
            public_activity: "执行失败",
            error: "Mock Agent 暂时无法完成这次只读验证。"
          });
        }
      } finally {
        this.executions.delete(workID);
      }
    });
  }

  update(workID, changes) {
    const current = this.get(workID);
    const updated = {
      ...current,
      ...changes,
      updated_at: this.now().toISOString()
    };
    this.store.save(updated);
    return updated;
  }
}

export function isTerminalWorkState(state) {
  return new Set(["completed", "cancelled", "failed"]).has(state);
}

function normalizeObjective(value) {
  const objective = String(value || "").trim().replace(/\s+/g, " ");
  if (!objective) throw new WorkValidationError("Work objective is required.");
  if (objective.length > 2_000) {
    throw new WorkValidationError("Work objective is too long.");
  }
  return objective;
}

function normalizeSubmissionKey(value) {
  const submissionKey = String(value || "").trim();
  if (!submissionKey) {
    throw new WorkValidationError("Work submission_key is required.");
  }
  if (submissionKey.length > 200) {
    throw new WorkValidationError("Work submission_key is too long.");
  }
  return submissionKey;
}

function normalizeWorkID(value) {
  const workID = String(value || "").trim();
  if (!/^work_[a-f0-9]{32}$/i.test(workID)) {
    throw new WorkValidationError("Invalid Work ID.");
  }
  return workID;
}

function abortableDelay(milliseconds, signal) {
  return new Promise((resolvePromise, rejectPromise) => {
    if (signal?.aborted) {
      rejectPromise(abortError());
      return;
    }
    const timer = setTimeout(resolvePromise, milliseconds);
    signal?.addEventListener("abort", () => {
      clearTimeout(timer);
      rejectPromise(abortError());
    }, { once: true });
  });
}

function abortError() {
  const error = new Error("Work was cancelled.");
  error.name = "AbortError";
  return error;
}
