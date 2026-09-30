const Notifier = require('./Notifier');

class WebhookNotifier extends Notifier {
  constructor(options = {}) {
    super({ ...options, channel: 'webhook', maxPerHour: options.maxPerHour || 10 });
  }

  validateUser(user) {
    super.validateUser(user);
    if (typeof user.webhookUrl !== 'string' || !user.webhookUrl.startsWith('https://')) {
      throw new TypeError('user.webhookUrl must be an https:// URL for webhook notifications');
    }
  }

  format(user, message, options = {}) {
    const formatted = super.format(user, message, options);
    return {
      ...formatted,
      url: user.webhookUrl,
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      json: JSON.stringify({
        title: formatted.title,
        body: formatted.body,
        category: formatted.metadata.category,
        userId: user.id
      })
    };
  }

  async deliver(payload) {
    if (typeof this.transport.webhook !== 'function') {
      throw new Error('webhook transport is not configured');
    }
    await this.transport.webhook(payload);
  }
}

module.exports = WebhookNotifier;
