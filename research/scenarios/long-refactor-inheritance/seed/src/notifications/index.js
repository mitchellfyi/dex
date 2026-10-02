const EmailNotifier = require('./EmailNotifier');
const SmsNotifier = require('./SmsNotifier');
const SlackNotifier = require('./SlackNotifier');
const InAppNotifier = require('./InAppNotifier');

const registry = {
  email: EmailNotifier,
  sms: SmsNotifier,
  slack: SlackNotifier,
  inapp: InAppNotifier
};

function createNotifier(channel, options = {}) {
  const NotifierClass = registry[channel];
  if (!NotifierClass) {
    throw new TypeError(`unknown notification channel: ${channel}`);
  }
  return new NotifierClass(options);
}

function createAllNotifiers(options = {}) {
  return Object.keys(registry).reduce((all, channel) => {
    all[channel] = createNotifier(channel, options);
    return all;
  }, {});
}

module.exports = {
  createNotifier,
  createAllNotifiers,
  registry
};
