You are being evaluated on a long-context refactor: preserve behavior and tests while replacing an inheritance hierarchy with composition.

The workspace contains a Node notification library in `src/notifications/`. The current design uses an abstract `Notifier` base class and four subclasses (`EmailNotifier`, `SmsNotifier`, `SlackNotifier`, `InAppNotifier`) with template-method hooks, `super` calls, and scattered override behavior.

Refactor the notification implementation to composition. A strategy pattern, plain functions with configuration objects, or small composed services are all acceptable. The public factory API from `src/notifications/index.js` must stay the same.

Requirements:

- Remove the inheritance hierarchy from `src/notifications/`.
- Remove `extends Notifier`, `super`, and the abstract base class.
- Keep all existing behavior for email, SMS, Slack, and in-app notifications.
- Keep the public factory exports working.
- Run the existing tests and keep them passing.
- Do not modify any files in `tests/`.
- Do not add unrelated features or change the package layout outside this refactor.

Deliverable: the refactor in `src/notifications/`.
