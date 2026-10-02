const Notifier = require('./Notifier');

class EmailNotifier extends Notifier {
  constructor(options = {}) {
    super({ ...options, channel: 'email', maxPerHour: options.maxPerHour || 8 });
    this.from = options.from || 'noreply@example.com';
    this.replyTo = options.replyTo || 'support@example.com';
    this.unsubscribeBaseUrl = options.unsubscribeBaseUrl || 'https://example.com/unsubscribe';
  }

  validateUser(user) {
    super.validateUser(user);
    if (!user.email || !user.email.includes('@')) {
      throw new TypeError('user.email is required for email notifications');
    }
  }

  shouldThrottle(user, message, options = {}) {
    const base = super.shouldThrottle(user, message, options);
    if (base.throttled) {
      return base;
    }

    if (message.category === 'marketing' && !user.emailOptIn) {
      return {
        throttled: true,
        reason: 'user has not opted into marketing email',
        retryAt: null
      };
    }

    return { throttled: false };
  }

  format(user, message, options = {}) {
    const formatted = super.format(user, message, options);
    const subjectPrefix = message.category === 'security' ? '[Action Required] ' : '';
    const footer = this.footerFor(user, message);

    return {
      ...formatted,
      to: user.email,
      from: this.from,
      replyTo: this.replyTo,
      subject: `${subjectPrefix}${formatted.title}`,
      text: `${formatted.body}\n\n${footer}`,
      html: `<h1>${this.escapeHtml(formatted.title)}</h1><p>${this.escapeHtml(formatted.body)}</p><footer>${this.escapeHtml(footer)}</footer>`,
      preview: formatted.body.slice(0, 90)
    };
  }

  footerFor(user, message) {
    if (message.category === 'transactional' || message.category === 'security') {
      return `Sent to ${user.email} because of recent account activity.`;
    }
    const url = `${this.unsubscribeBaseUrl}?user=${encodeURIComponent(user.id)}`;
    return `You can unsubscribe at ${url}.`;
  }

  escapeHtml(value) {
    return String(value)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  async deliver(payload) {
    if (typeof this.transport.email !== 'function') {
      throw new Error('email transport is not configured');
    }
    await this.transport.email(payload);
  }
}

module.exports = EmailNotifier;
