import http from 'k6/http';
import { sleep } from 'k6';

export const options = {
  vus: 1,          // 1 user
  duration: '30s', // 30 seconds
};

export default function () {
  http.get('http://34.170.63.98:80'); // Try :80 first
  sleep(1);
}
