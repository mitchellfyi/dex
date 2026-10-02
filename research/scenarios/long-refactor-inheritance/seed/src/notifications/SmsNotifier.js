const Notifier = require('./Notifier');

class SmsNotifier extends Notifier {
  constructor(options = {}) {
    super({ ...options, channel: 'sms', maxPerHour: options.maxPerHour || 4 });
    this.senderId = options.senderId || 'APP';
    this.segmentLength = options.segmentLength || 140;
  }

  validateUser(user) {
    super.validateUser(user);
    if (!user.phone || !/^\+[1-9]\d{6,14}$/.test(user.phone)) {
      throw new TypeError('user.phone must be E.164 for SMS notifications');
    }
  }

  shouldThrottle(user, message, options = {}) {
    const base = super.shouldThrottle(user, message, options);
    if (base.throttled) {
      return base;
    }

    if (message.category === 'marketing' && !user.smsOptIn) {
      return {
        throttled: true,
        reason: 'user has not opted into marketing SMS',
        retryAt: null
      };
    }

    return { throttled: false };
  }

  format(user, message, options = {}) {
    const formatted = super.format(user, message, options);
    const prefix = message.priority === 'urgent' ? 'URGENT: ' : '';
    const composed = `${prefix}${formatted.title} - ${formatted.body}`;
    const text = this.truncate(composed);

    return {
      ...formatted,
      to: user.phone,
      from: this.senderId,
      text,
      segments: Math.ceil(text.length / this.segmentLength),
      preview: text
    };
  }

  truncate(value) {
    if (value.length <= this.segmentLength) {
      return value;
    }
    return `${value.slice(0, this.segmentLength - 1)}…`;
  }

  async deliver(payload) {
    if (typeof this.transport.sms !== 'function') {
      throw new Error('sms transport is not configured');
    }
    await this.transport.sms(payload);
  }
}

module.exports = SmsNotifier;
