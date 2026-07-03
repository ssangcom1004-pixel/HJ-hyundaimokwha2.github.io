const express = require('express');
const path = require('path');
const fs = require('fs');
const os = require('os');
const cors = require('cors');
const QRCode = require('qrcode');

const app = express();
const PORT = process.env.PORT || 3000;
const CSV_FILE_PATH = path.join(__dirname, 'completions.csv');

app.use(cors());
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

// Helper to get local network IP address
function getLocalIPAddress() {
  const interfaces = os.networkInterfaces();
  for (const interfaceName in interfaces) {
    for (const iface of interfaces[interfaceName]) {
      // IPv4 and not internal (localhost)
      if (iface.family === 'IPv4' && !iface.internal) {
        return iface.address;
      }
    }
  }
  return 'localhost';
}

const LOCAL_IP = getLocalIPAddress();
const APP_URL = `http://${LOCAL_IP}:${PORT}`;

// Initialize completions.csv if it doesn't exist
if (!fs.existsSync(CSV_FILE_PATH)) {
  const header = 'Name,DateOfBirth,CompletionTime\n';
  fs.writeFileSync(CSV_FILE_PATH, header, 'utf8');
}

// API: Get QR Code URL and current status
app.get('/api/status', async (req, res) => {
  try {
    const qrCodeDataUrl = await QRCode.toDataURL(APP_URL);
    res.json({
      url: APP_URL,
      qrCode: qrCodeDataUrl,
      port: PORT,
      ip: LOCAL_IP
    });
  } catch (error) {
    res.status(500).json({ error: 'Failed to generate QR Code' });
  }
});

// API: Submit completion
app.post('/api/complete', (req, res) => {
  const { name, dob } = req.body;

  if (!name || !dob) {
    return res.status(400).json({ error: '이름과 생년월일을 입력해주세요.' });
  }

  // Clean data to prevent CSV injection
  const cleanName = name.replace(/,/g, '').trim();
  const cleanDob = dob.replace(/,/g, '').trim();
  const timestamp = new Date().toLocaleString('ko-KR', { timeZone: 'Asia/Seoul' });

  const record = `"${cleanName}","${cleanDob}","${timestamp}"\n`;

  fs.appendFile(CSV_FILE_PATH, record, 'utf8', (err) => {
    if (err) {
      console.error('CSV 쓰기 에러:', err);
      return res.status(500).json({ error: '데이터 저장 중 오류가 발생했습니다.' });
    }
    res.json({ success: true, timestamp });
  });
});

// API: Get completions list
app.get('/api/completions', (req, res) => {
  fs.readFile(CSV_FILE_PATH, 'utf8', (err, data) => {
    if (err) {
      return res.status(500).json({ error: '이수 목록을 불러올 수 없습니다.' });
    }

    const lines = data.trim().split('\n');
    const headers = lines[0].split(',');
    const list = [];

    for (let i = 1; i < lines.length; i++) {
      if (!lines[i]) continue;
      // Parse CSV line considering double quotes
      const matches = lines[i].match(/(".*?"|[^",\s]+)(?=\s*,|\s*$)/g);
      if (matches && matches.length >= 3) {
        list.push({
          name: matches[0].replace(/"/g, ''),
          dob: matches[1].replace(/"/g, ''),
          time: matches[2].replace(/"/g, '')
        });
      }
    }
    res.json({ completions: list });
  });
});

// API: Download completions.csv
app.get('/api/download', (req, res) => {
  if (fs.existsSync(CSV_FILE_PATH)) {
    res.download(CSV_FILE_PATH, 'education_completions.csv');
  } else {
    res.status(404).send('이수 완료 파일이 존재하지 않습니다.');
  }
});

// Serve admin page
app.get('/admin', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'admin.html'));
});

app.listen(PORT, () => {
  console.log('==================================================');
  console.log(` 교육 완료 관리 서버가 구동되었습니다.`);
  console.log(` - 로컬 주소: http://localhost:${PORT}`);
  console.log(` - 네트워크 주소 (QR코드 링크): ${APP_URL}`);
  console.log(` - 관리자 페이지: http://localhost:${PORT}/admin`);
  console.log('==================================================');
});
