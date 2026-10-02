const Notifier = require('./Notifier');

class SlackNotifier extends Notifier {
  constructor(options = {}) {
    super({ ...options, channel: 'slack', maxPerHour: options.maxPerHour || 20 });
    this.defaultWorkspace = options.defaultWorkspace || 'main';
    this.defaultChannel = options.defaultChannel || '#general';
  }

  validateUser(user) {
    super.validateUser(user);
    if (!user.slackId && !user.slackChannel) {
      throw new TypeError('user.slackId or user.slackChannel is required for Slack notifications');
    }
  }

  shouldThrottle(user, message, options = {}) {
    if (options.threadTs) {
      return { throttled: false };
    }
    return super.shouldThrottle(user, message, options);
  }

  format(user, message, options = {}) {
    const formatted = super.format(user, message, options);
    const channel = options.channel || user.slackChannel || this.defaultChannel;
    const mention = user.slackId ? `<@${user.slackId}> ` : '';
    const text = `${mention}*${formatted.title}*\n${formatted.body}`;

    return {
      ...formatted,
      workspace: user.slackWorkspace || this.defaultWorkspace,
      channel,
      threadTs: options.threadTs || null,
      text,
      blocks: this.blocksFor(formatted, mention),
      preview: text.replace(/\*/g, '').slice(0, 120)
    };
  }

  blocksFor(formatted, mention) {
    return [
      {
        type: 'section',
        text: {
          type: 'mrkdwn',
          text: `${mention}*${formatted.title}*`
        }
      },
      {
        type: 'section',
        text: {
          type: 'mrkdwn',
          text: formatted.body
        }
      },
      {
        type: 'context',
        elements: [
          {
            type: 'mrkdwn',
            text: `Category: ${formatted.metadata.category}`
          }
        ]
      }
    ];
  }

  async deliver(payload) {
    if (typeof this.transport.slack !== 'function') {
      throw new Error('slack transport is not configured');
    }
    await this.transport.slack(payload);
  }
}

module.exports = SlackNotifier;
