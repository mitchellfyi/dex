const Notifier = require('./Notifier');

class InAppNotifier extends Notifier {
  constructor(options = {}) {
    super({ ...options, channel: 'inapp', maxPerHour: options.maxPerHour || 50 });
    this.defaultIcon = options.defaultIcon || 'bell';
    this.defaultAction = options.defaultAction || '/notifications';
  }

  validateUser(user) {
    super.validateUser(user);
    if (user.disabledInApp) {
      throw new TypeError('in-app notifications are disabled for this user');
    }
  }

  shouldThrottle(user, message, options = {}) {
    if (message.category === 'security') {
      return { throttled: false };
    }
    return super.shouldThrottle(user, message, options);
  }

  format(user, message, options = {}) {
    const formatted = super.format(user, message, options);
    const expiresInHours = options.expiresInHours || (message.priority === 'urgent' ? 72 : 168);
    const expiresAt = new Date(this.now().getTime() + expiresInHours * 60 * 60 * 1000);

    return {
      ...formatted,
      userId: user.id,
      icon: message.icon || this.defaultIcon,
      actionUrl: options.actionUrl || message.actionUrl || this.defaultAction,
      read: false,
      expiresAt: expiresAt.toISOString(),
      preview: formatted.title
    };
  }

  async deliver(payload) {
    if (typeof this.transport.inapp !== 'function') {
      throw new Error('in-app transport is not configured');
    }
    await this.transport.inapp(payload);
  }
}

module.exports = InAppNotifier;
