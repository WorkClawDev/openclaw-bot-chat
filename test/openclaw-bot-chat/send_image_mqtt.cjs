const mqtt = require('mqtt');
const fs = require('fs');

const IMAGE_PATH = '/home/changer/.openclaw/media/tool-image-generation/image-1---320df7d4-893f-40c8-833c-22f5fb95bb27.jpg';
const MQTT_URL = 'mqtt://127.0.0.1:1883';
const BOT_ID = '32fc5060-6624-4c5d-8929-ae75710cca9b';
const USER_ID = 'c5811acd-4924-4dd0-bd68-a4cf29dd707d';

const client = mqtt.connect(MQTT_URL, {
  username: 'openclaw_backend',
  password: 'change-me-in-production',
  clientId: `bot-${BOT_ID}-test-image-${Date.now()}`,
});

client.on('connect', async () => {
  console.log('Connected to MQTT');

  const topic = `chat/dm/user/${USER_ID}/bot/${BOT_ID}`;

  const payload = {
    id: `test-${Date.now()}`,
    topic,
    conversation_id: `chat/dm/user/${USER_ID}/bot/${BOT_ID}`,
    from: { type: 'bot', id: BOT_ID },
    to: { type: 'user', id: USER_ID },
    content: {
      type: 'image',
      body: '一只小沙蟹 🦀☀️',
      meta: {
        asset: {
          source_url: `http://127.0.0.1:19876/image-1---320df7d4-893f-40c8-833c-22f5fb95bb27.jpg`,
          file_name: 'sand_crab.jpg',
          mime_type: 'image/jpeg'
        }
      }
    },
    timestamp: Math.floor(Date.now() / 1000)
  };

  console.log('Publishing image message...');
  client.publish(topic, JSON.stringify(payload), { qos: 1 }, (err) => {
    if (err) {
      console.error('Publish error:', err);
    } else {
      console.log('Image message published successfully');
    }
    client.end();
  });
});

client.on('error', (err) => {
  console.error('MQTT error:', err);
  client.end();
});
