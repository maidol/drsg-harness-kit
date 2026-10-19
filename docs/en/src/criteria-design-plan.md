# Criteria, design, plan

The rules live in the "判据、设计、执行计划" section of [`claude/CROSS-PROJECT-REVIEW.md`](https://github.com/maidol/drsg-harness-kit/blob/main/claude/CROSS-PROJECT-REVIEW.md); this page explains them and gives one complete example.

## What each layer answers

- **Criteria**: what counts as done and correct? Only externally observable behaviour; a different design leaves the criteria unchanged.
- **Design**: which approach gets there? Modules, interfaces, key logic, trade-offs, blast radius, degradation.
- **Execution plan**: in what order and in how many steps, and how is each step confirmed?

Review top-down: criteria not agreed, no design review; design not passed, no plan review. Accept bottom-up: each step is verified against the plan, the result against the criteria, item by item.

## Example: brute-force protection for a login endpoint

### Criteria (seven-field template, no implementation)

```text
【目标】Stop password brute-forcing on the login endpoint without affecting normal users
【成功标准】
  1. 5 consecutive wrong passwords for one account lock it for 15 minutes and return ACCOUNT_LOCKED
  2. More than 20 login attempts per minute from one IP return 429
  3. 1 to 4 wrong attempts followed by the right password log in normally and reset the counter
【边界情况】
  - Correct password while locked: still refused
  - Lock expiry: released automatically, no manual step
  - Unknown account: counted the same, same message as a wrong password, so accounts cannot be enumerated
【不做的事】CAPTCHA, SMS or e-mail notification, an unlock button in the admin console
【约束】Request and response format of the login endpoint unchanged; P99 latency grows by at most 10ms
【验收方式】Automated tests cover success criteria 1–3 and every edge case; the reviewer reruns them on the same tree
【未决问题】Whether thresholds become configurable: product decides next week; this release uses config defaults
```

The field names stay in Chinese because they are the literal template the rules ask for. The "unknown account" line is the kind of thing the author knows but finds too obvious to write down, and a weaker executor will not think of enumeration; the template forces it onto the page.

### Design (the chosen approach and why)

- Counters in Redis: they need expiry and must take frequent writes.
- Keys `login_fail:{account}` and `login_rate:{ip}`; TTL does the unlocking.
- Intercept in the authentication middleware; the business layer is untouched.
- Trade-off: when Redis is down, let requests through rather than refuse them.
- Blast radius: the middleware and its config, not the user table.

Had "count failures in Redis" been written into the criteria, acceptance would check whether Redis was used instead of whether brute-forcing was stopped.

### Execution plan (step by step)

1. Config and the Redis counter helper, with unit tests, about 80 lines.
2. Account locking in the middleware, with integration tests for the 5-failure lock and expiry, about 120 lines.
3. Per-IP rate limit, with tests, about 60 lines.
4. Redis failure degradation, with fault-injection tests, about 50 lines.

Every step can be committed and verified on its own, and the system works after any of them.

### Verdict of a staged review

```text
设计：通过
计划：需修订（第 2 步缺验证命令）
```

The Event summary starts `设计通过，计划需修订：…` ("design passed, plan needs revision"); when the design fails it is just `设计需修订：…` and the plan is not reviewed.

### When acceptance fails

The verdict cites item numbers and the summary carries reason categories:

```text
验收不通过：[漏测边界] 2 不通过：超限返回了 500 而不是 429
```

There are seven categories: 判据缺失 (missing criteria), 理解偏差 (misread requirement), 方案不成立 (unsound design), 漏测边界 (untested edge case), 范围偏移 (scope drift), 钻判据空子 (gaming the criteria), 约定不符 (convention mismatch). Section 7 of `agent-efficiency-retro` counts them into a first-pass rate and a reason breakdown.
