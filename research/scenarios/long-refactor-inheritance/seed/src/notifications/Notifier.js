class Notifier {
  constructor(options = {}) {
    if (new.target === Notifier) {
      throw new TypeError('Notifier is abstract');
    }

    this.channel = options.channel;
    this.transport = options.transport || {};
    this.templates = options.templates || {};
    this.throttleStore = options.throttleStore || new Map();
    this.now = options.now || (() => new Date());
    this.defaultSender = options.defaultSender || 'Product Team';
    this.defaultLocale = options.defaultLocale || 'en-US';
    this.maxPerHour = options.maxPerHour || 3;
  }

  async send(user, message, options = {}) {
    this.validateUser(user);
    this.validateMessage(message);

    const throttle = this.shouldThrottle(user, message, options);
    if (throttle.throttled) {
      return {
        channel: this.channel,
        status: 'throttled',
        reason: throttle.reason,
        retryAt: throttle.retryAt,
        userId: user.id
      };
    }

    const formatted = this.format(user, message, options);
    await this.deliver(formatted, user, message, options);
    this.recordDelivery(user, message, options);

    return {
      channel: this.channel,
      status: 'sent',
      userId: user.id,
      id: formatted.id,
      preview: formatted.preview
    };
  }

  validateUser(user) {
    if (!user || typeof user !== 'object') {
      throw new TypeError('user is required');
    }
    if (!user.id) {
      throw new TypeError('user.id is required');
    }
  }

  validateMessage(message) {
    if (!message || typeof message !== 'object') {
      throw new TypeError('message is required');
    }
    if (!message.title || !message.body) {
      throw new TypeError('message.title and message.body are required');
    }
  }

  shouldThrottle(user, message, options = {}) {
    if (options.force || message.priority === 'urgent') {
      return { throttled: false };
    }

    const key = this.throttleKey(user, message);
    const now = this.now().getTime();
    const windowMs = 60 * 60 * 1000;
    const records = (this.throttleStore.get(key) || []).filter(ts => now - ts < windowMs);

    if (records.length >= this.maxPerHour) {
      return {
        throttled: true,
        reason: `${this.channel} hourly limit reached`,
        retryAt: new Date(records[0] + windowMs).toISOString()
      };
    }

    return { throttled: false };
  }

  throttleKey(user, message) {
    const category = message.category || 'general';
    return `${this.channel}:${user.id}:${category}`;
  }

  format(user, message, options = {}) {
    const id = `${this.channel}-${user.id}-${this.now().getTime()}`;
    const locale = options.locale || user.locale || this.defaultLocale;
    const title = this.applyTemplate(message.title, user, message);
    const body = this.applyTemplate(message.body, user, message);

    return {
      id,
      channel: this.channel,
      locale,
      title,
      body,
      preview: `${title}: ${body}`.slice(0, 120),
      metadata: {
        category: message.category || 'general',
        priority: message.priority || 'normal',
        generatedAt: this.now().toISOString()
      }
    };
  }

  applyTemplate(value, user, message) {
    return String(value)
      .replace(/\{\{name\}\}/g, user.name || 'there')
      .replace(/\{\{id\}\}/g, user.id)
      .replace(/\{\{category\}\}/g, message.category || 'general');
  }

  recordDelivery(user, message) {
    const key = this.throttleKey(user, message);
    const records = this.throttleStore.get(key) || [];
    records.push(this.now().getTime());
    this.throttleStore.set(key, records);
  }

  async deliver() {
    throw new Error(`${this.channel} deliver() must be implemented`);
  }
}

module.exports = Notifier;
