// b1tpoti0n Admin UI - Alpine.js version

// =============================================================================
// Demo Mode Detection
// =============================================================================

const isDemo = window.location.hostname.includes('github.io') || window.location.search.includes('demo=1');

// =============================================================================
// Demo Data
// =============================================================================

const demoData = {
  stats: {
    users: 1247,
    torrents: 8934,
    peers: 15623,
    active_swarms: 2841,
    total_snatches: 89234,
    hnr_count: 23,
    active_bans: 8,
    total_uploaded: 847293847293847,
    total_downloaded: 293847293847293,
    whitelisted_clients: 9,
    ets: { passkeys: 1247, whitelist: 9, banned_ips: 8 }
  },
  users: [
    { id: 1, passkey: 'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4', uploaded: 1572864000000, downloaded: 524288000000, bonus_points: 342.5, hnr_warnings: 0, can_leech: true, created_at: '2024-03-15T10:30:00Z' },
    { id: 2, passkey: 'b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5', uploaded: 8589934592000, downloaded: 2147483648000, bonus_points: 1205.75, hnr_warnings: 0, can_leech: true, created_at: '2024-01-22T14:45:00Z' },
    { id: 3, passkey: 'c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6', uploaded: 107374182400, downloaded: 536870912000, bonus_points: 45.2, hnr_warnings: 2, can_leech: true, created_at: '2024-06-08T09:15:00Z' },
    { id: 4, passkey: 'd4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1', uploaded: 0, downloaded: 10737418240, bonus_points: 0, hnr_warnings: 3, can_leech: false, created_at: '2024-11-02T16:20:00Z' },
    { id: 5, passkey: 'e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2', uploaded: 42949672960000, downloaded: 10737418240000, bonus_points: 5420.0, hnr_warnings: 0, can_leech: true, created_at: '2023-08-14T11:00:00Z' },
  ],
  torrents: [
    { id: 1, info_hash: 'a1b2c3d4e5f6789012345678901234567890', seeders: 45, leechers: 12, completed: 892, freeleech: true, upload_multiplier: 1.0, download_multiplier: 0.0, created_at: '2024-10-01T08:00:00Z' },
    { id: 2, info_hash: 'b2c3d4e5f67890123456789012345678901a', seeders: 128, leechers: 34, completed: 2341, freeleech: false, upload_multiplier: 2.0, download_multiplier: 1.0, created_at: '2024-09-15T12:30:00Z' },
    { id: 3, info_hash: 'c3d4e5f6789012345678901234567890123b', seeders: 8, leechers: 2, completed: 156, freeleech: false, upload_multiplier: 1.0, download_multiplier: 0.5, created_at: '2024-11-20T15:45:00Z' },
    { id: 4, info_hash: 'd4e5f67890123456789012345678901234c5', seeders: 312, leechers: 89, completed: 5678, freeleech: false, upload_multiplier: 1.0, download_multiplier: 1.0, created_at: '2024-07-04T09:00:00Z' },
    { id: 5, info_hash: 'e5f678901234567890123456789012345d67', seeders: 67, leechers: 15, completed: 1023, freeleech: true, upload_multiplier: 1.5, download_multiplier: 0.0, created_at: '2024-12-01T18:20:00Z' },
  ],
  whitelist: [
    { id: 1, prefix: '-TR', name: 'Transmission', created_at: '2024-01-01T00:00:00Z' },
    { id: 2, prefix: '-qB', name: 'qBittorrent', created_at: '2024-01-01T00:00:00Z' },
    { id: 3, prefix: '-DE', name: 'Deluge', created_at: '2024-01-01T00:00:00Z' },
    { id: 4, prefix: '-UT', name: 'uTorrent', created_at: '2024-01-01T00:00:00Z' },
    { id: 5, prefix: '-lt', name: 'libtorrent (rasterbar)', created_at: '2024-01-01T00:00:00Z' },
    { id: 6, prefix: '-LT', name: 'libtorrent (rakshasa)', created_at: '2024-01-01T00:00:00Z' },
    { id: 7, prefix: '-AZ', name: 'Azureus/Vuze', created_at: '2024-01-01T00:00:00Z' },
    { id: 8, prefix: '-BT', name: 'BitTorrent', created_at: '2024-01-01T00:00:00Z' },
    { id: 9, prefix: '-WW', name: 'WebTorrent', created_at: '2024-01-01T00:00:00Z' },
  ],
  bans: [
    { id: 1, ip: '192.168.1.100', reason: 'Ratio cheating detected', expires_at: null, created_at: '2024-12-10T14:30:00Z' },
    { id: 2, ip: '10.0.0.55', reason: 'Spam announces', expires_at: '2025-01-15T00:00:00Z', created_at: '2024-12-15T09:00:00Z' },
    { id: 3, ip: '172.16.0.42', reason: 'Client spoofing', expires_at: null, created_at: '2024-11-28T16:45:00Z' },
  ],
  hnr: [
    { id: 101, user_id: 4, torrent_id: 2, completed_at: '2024-11-15T10:00:00Z', seedtime: 3600, seedtime_hours: 1.0, hnr: true },
    { id: 102, user_id: 3, torrent_id: 4, completed_at: '2024-12-01T14:30:00Z', seedtime: 18000, seedtime_hours: 5.0, hnr: true },
  ],
  swarms: [
    { info_hash: 'a1b2c3d4e5f6789012345678901234567890', seeders: 45, leechers: 12, completed: 892 },
    { info_hash: 'b2c3d4e5f67890123456789012345678901a', seeders: 128, leechers: 34, completed: 2341 },
    { info_hash: 'd4e5f67890123456789012345678901234c5', seeders: 312, leechers: 89, completed: 5678 },
    { info_hash: 'e5f678901234567890123456789012345d67', seeders: 67, leechers: 15, completed: 1023 },
    { info_hash: 'f6789012345678901234567890123456e789', seeders: 23, leechers: 8, completed: 445 },
    { info_hash: '78901234567890123456789012345678f901', seeders: 89, leechers: 21, completed: 1876 },
  ],
  rateLimits: {
    enabled: true,
    total_ips_tracked: 892,
    limits: { announce: '30/min', scrape: '10/min', admin_api: '100/min' }
  },
  bonus: {
    enabled: true,
    base_points: 1.0,
    conversion_rate: 1000000000,
    last_calculation: '2024-12-26T12:00:00Z'
  },
  verification: {
    enabled: true,
    cache_size: 2341,
    verified_count: 1892,
    failed_count: 449
  }
};

// =============================================================================
// Global State & Config
// =============================================================================

const config = {
  apiUrl: localStorage.getItem('apiUrl') || 'http://localhost:8080',
  adminToken: localStorage.getItem('adminToken') || ''
};

// =============================================================================
// API Helper
// =============================================================================

async function api(method, path, body = null) {
  const url = config.apiUrl + '/admin' + path;
  const opts = {
    method,
    headers: {
      'Content-Type': 'application/json',
      'X-Admin-Token': config.adminToken
    }
  };
  if (body) opts.body = JSON.stringify(body);

  try {
    const res = await fetch(url, opts);
    const data = await res.json();
    if (!data.success) {
      toast(data.error || 'Request failed', 'error');
    } else if (data.message) {
      toast(data.message, 'success');
    }
    return data;
  } catch (e) {
    toast('Network error: ' + e.message, 'error');
    return { success: false, error: e.message };
  }
}

// =============================================================================
// Utilities
// =============================================================================

function toast(msg, type = 'success') {
  const t = document.createElement('div');
  t.className = 'toast ' + type;
  t.textContent = msg;
  document.body.appendChild(t);
  setTimeout(() => t.remove(), 3000);
}

function formatBytes(b) {
  if (b >= 1e12) return (b / 1e12).toFixed(2) + ' TB';
  if (b >= 1e9) return (b / 1e9).toFixed(2) + ' GB';
  if (b >= 1e6) return (b / 1e6).toFixed(2) + ' MB';
  if (b >= 1e3) return (b / 1e3).toFixed(2) + ' KB';
  return b + ' B';
}

function ratio(up, down) {
  return down > 0 ? (up / down).toFixed(2) : 'Inf';
}

function saveConfig() {
  localStorage.setItem('apiUrl', config.apiUrl);
  localStorage.setItem('adminToken', config.adminToken);
}

// =============================================================================
// Alpine.js Data Stores
// =============================================================================

document.addEventListener('alpine:init', () => {
  // Main app store
  Alpine.store('app', {
    section: 'stats',
    connected: isDemo,

    async connect() {
      if (isDemo) {
        toast('Demo mode - no connection needed', 'success');
        return;
      }
      saveConfig();
      const data = await api('GET', '/stats');
      if (data.success) {
        this.connected = true;
        toast('Connected!', 'success');
      }
    },

    showSection(id) {
      this.section = id;
    }
  });
});

// =============================================================================
// Alpine.js Components
// =============================================================================

// Dashboard component
function dashboardData() {
  return {
    stats: {},
    loading: true,
    async load() {
      this.loading = true;
      if (isDemo) {
        this.stats = demoData.stats;
      } else {
        const data = await api('GET', '/stats');
        if (data.success) this.stats = data.data;
      }
      this.loading = false;
    },
    async flush() { if (isDemo) { toast('Demo: Stats flushed to database', 'success'); return; } await api('POST', '/stats/flush'); },
    async hnrCheck() { if (isDemo) { toast('Demo: HnR check completed', 'success'); return; } await api('POST', '/hnr/check'); },
    async calcBonus() { if (isDemo) { toast('Demo: Bonus points calculated', 'success'); return; } await api('POST', '/bonus/calculate'); },
    async cleanupBans() { if (isDemo) { toast('Demo: Expired bans cleaned up', 'success'); return; } await api('POST', '/bans/cleanup'); }
  };
}

// Users component
function usersData() {
  return {
    users: [],
    search: '',
    editModal: false,
    createModal: false,
    editUser: null,
    newPasskey: '',
    loading: true,

    async load() {
      this.loading = true;
      if (isDemo) {
        this.users = demoData.users;
      } else {
        const data = await api('GET', '/users');
        if (data.success) this.users = data.data;
      }
      this.loading = false;
    },

    async searchUsers() {
      if (this.search.length < 3) {
        toast('Search requires at least 3 characters', 'error');
        return;
      }
      this.loading = true;
      const data = await api('GET', '/users/search?q=' + encodeURIComponent(this.search));
      if (data.success) this.users = data.data;
      this.loading = false;
    },

    async create() {
      const body = this.newPasskey ? { passkey: this.newPasskey } : {};
      const data = await api('POST', '/users', body);
      if (data.success) {
        this.createModal = false;
        this.newPasskey = '';
        await this.load();
      }
    },

    async edit(id) {
      const data = await api('GET', '/users/' + id);
      if (data.success) {
        this.editUser = { ...data.data };
        this.editModal = true;
      }
    },

    async saveEdit() {
      const id = this.editUser.id;
      await api('PUT', '/users/' + id + '/stats', {
        uploaded: parseInt(this.editUser.uploaded),
        downloaded: parseInt(this.editUser.downloaded),
        operation: 'set'
      });
      await api('PUT', '/users/' + id + '/leech', {
        can_leech: this.editUser.can_leech
      });
      this.editModal = false;
      await this.load();
    },

    async resetPasskey(id) {
      if (confirm('Reset passkey for user ' + id + '?')) {
        await api('POST', '/users/' + id + '/reset');
        await this.load();
      }
    },

    async deleteUser(id) {
      if (confirm('Delete user ' + id + '?')) {
        await api('DELETE', '/users/' + id);
        await this.load();
      }
    },

    async clearWarnings(id) {
      await api('POST', '/users/' + id + '/warnings/clear');
      this.editModal = false;
      await this.load();
    }
  };
}

// Torrents component
function torrentsData() {
  return {
    torrents: [],
    newHash: '',
    editModal: false,
    editTorrent: null,
    loading: true,

    async load() {
      this.loading = true;
      if (isDemo) {
        this.torrents = demoData.torrents;
      } else {
        const data = await api('GET', '/torrents');
        if (data.success) this.torrents = data.data;
      }
      this.loading = false;
    },

    async register() {
      if (this.newHash.length !== 40) {
        toast('Info hash must be 40 hex characters', 'error');
        return;
      }
      const data = await api('POST', '/torrents', { info_hash: this.newHash });
      if (data.success) {
        this.newHash = '';
        await this.load();
      }
    },

    async toggleFL(id, enable) {
      if (enable) {
        await api('POST', '/torrents/' + id + '/freeleech');
      } else {
        await api('DELETE', '/torrents/' + id + '/freeleech');
      }
      await this.load();
    },

    async edit(id) {
      const data = await api('GET', '/torrents/' + id);
      if (data.success) {
        this.editTorrent = { ...data.data };
        this.editModal = true;
      }
    },

    async saveEdit() {
      const id = this.editTorrent.id;
      await api('PUT', '/torrents/' + id + '/multipliers', {
        upload_multiplier: parseFloat(this.editTorrent.upload_multiplier),
        download_multiplier: parseFloat(this.editTorrent.download_multiplier)
      });
      await api('PUT', '/torrents/' + id + '/stats', {
        seeders: parseInt(this.editTorrent.seeders),
        leechers: parseInt(this.editTorrent.leechers)
      });
      this.editModal = false;
      await this.load();
    },

    async deleteTorrent(id) {
      if (confirm('Delete torrent ' + id + '?')) {
        await api('DELETE', '/torrents/' + id);
        await this.load();
      }
    }
  };
}

// Whitelist component
function whitelistData() {
  return {
    items: [],
    newPrefix: '',
    newName: '',
    loading: true,

    async load() {
      this.loading = true;
      if (isDemo) {
        this.items = demoData.whitelist;
      } else {
        const data = await api('GET', '/whitelist');
        if (data.success) this.items = data.data;
      }
      this.loading = false;
    },

    async add() {
      if (!this.newPrefix || !this.newName) {
        toast('Prefix and name required', 'error');
        return;
      }
      const data = await api('POST', '/whitelist', { prefix: this.newPrefix, name: this.newName });
      if (data.success) {
        this.newPrefix = '';
        this.newName = '';
        await this.load();
      }
    },

    async remove(prefix) {
      if (confirm('Remove ' + prefix + ' from whitelist?')) {
        await api('DELETE', '/whitelist/' + encodeURIComponent(prefix));
        await this.load();
      }
    }
  };
}

// Bans component
function bansData() {
  return {
    bans: [],
    newIp: '',
    newReason: '',
    newDuration: '',
    loading: true,

    async load(activeOnly = false) {
      this.loading = true;
      if (isDemo) {
        this.bans = demoData.bans;
      } else {
        const path = activeOnly ? '/bans/active' : '/bans';
        const data = await api('GET', path);
        if (data.success) this.bans = data.data;
      }
      this.loading = false;
    },

    async ban() {
      if (!this.newIp || !this.newReason) {
        toast('IP and reason required', 'error');
        return;
      }
      const body = { ip: this.newIp, reason: this.newReason };
      if (this.newDuration) body.duration = parseInt(this.newDuration);
      const data = await api('POST', '/bans', body);
      if (data.success) {
        this.newIp = '';
        this.newReason = '';
        this.newDuration = '';
        await this.load();
      }
    },

    async unban(ip) {
      if (confirm('Unban ' + ip + '?')) {
        await api('DELETE', '/bans/' + encodeURIComponent(ip));
        await this.load();
      }
    }
  };
}

// Rate limits component
function rateLimitsData() {
  return {
    stats: null,
    ip: '',
    ipState: null,
    loading: true,

    async load() {
      this.loading = true;
      if (isDemo) {
        this.stats = demoData.rateLimits;
      } else {
        const data = await api('GET', '/ratelimits');
        if (data.success) this.stats = data.data;
      }
      this.loading = false;
    },

    async checkIp() {
      if (!this.ip) { toast('Enter an IP address', 'error'); return; }
      const data = await api('GET', '/ratelimits/' + encodeURIComponent(this.ip));
      if (data.success) this.ipState = data.data;
    },

    async resetIp() {
      if (!this.ip) { toast('Enter an IP address', 'error'); return; }
      await api('DELETE', '/ratelimits/' + encodeURIComponent(this.ip));
      this.ipState = null;
    }
  };
}

// Snatches component
function snatchesData() {
  return {
    snatches: [],
    userId: '',
    torrentId: '',
    loading: false,

    async loadByUser() {
      if (!this.userId) { toast('Enter a user ID', 'error'); return; }
      this.loading = true;
      const data = await api('GET', '/users/' + this.userId + '/snatches');
      if (data.success) this.snatches = data.data;
      this.loading = false;
    },

    async loadByTorrent() {
      if (!this.torrentId) { toast('Enter a torrent ID', 'error'); return; }
      this.loading = true;
      const data = await api('GET', '/torrents/' + this.torrentId + '/snatches');
      if (data.success) this.snatches = data.data;
      this.loading = false;
    },

    async clearHnr(id) {
      await api('DELETE', '/snatches/' + id + '/hnr');
      // Reload if we have a context
      if (this.userId) await this.loadByUser();
      else if (this.torrentId) await this.loadByTorrent();
    },

    async deleteSnatch(id) {
      if (confirm('Delete snatch ' + id + '?')) {
        await api('DELETE', '/snatches/' + id);
        if (this.userId) await this.loadByUser();
        else if (this.torrentId) await this.loadByTorrent();
      }
    }
  };
}

// HnR component
function hnrData() {
  return {
    violations: [],
    loading: true,

    async load() {
      this.loading = true;
      if (isDemo) {
        this.violations = demoData.hnr;
      } else {
        const data = await api('GET', '/hnr');
        if (data.success) this.violations = data.data;
      }
      this.loading = false;
    },

    async check() {
      await api('POST', '/hnr/check');
      await this.load();
    },

    async clearHnr(id) {
      await api('DELETE', '/snatches/' + id + '/hnr');
      await this.load();
    }
  };
}

// Bonus component
function bonusData() {
  return {
    stats: null,
    userId: '',
    points: '',
    loading: true,

    async load() {
      this.loading = true;
      if (isDemo) {
        this.stats = demoData.bonus;
      } else {
        const data = await api('GET', '/bonus/stats');
        if (data.success) this.stats = data.data;
      }
      this.loading = false;
    },

    async getPoints() {
      if (!this.userId) { toast('Enter a user ID', 'error'); return; }
      const data = await api('GET', '/users/' + this.userId + '/points');
      if (data.success) {
        this.points = data.data.bonus_points;
        toast('User has ' + data.data.bonus_points.toFixed(2) + ' points', 'success');
      }
    },

    async addPoints() {
      if (!this.userId || !this.points) { toast('User ID and points required', 'error'); return; }
      await api('POST', '/users/' + this.userId + '/points', { points: parseFloat(this.points) });
    },

    async removePoints() {
      if (!this.userId || !this.points) { toast('User ID and points required', 'error'); return; }
      await api('DELETE', '/users/' + this.userId + '/points', { points: parseFloat(this.points) });
    },

    async redeem() {
      if (!this.userId || !this.points) { toast('User ID and points required', 'error'); return; }
      const data = await api('POST', '/users/' + this.userId + '/redeem', { points: parseFloat(this.points) });
      if (data.success) {
        toast('Redeemed for ' + data.data.upload_credit_formatted, 'success');
      }
    },

    async calculate() {
      await api('POST', '/bonus/calculate');
    }
  };
}

// Swarms component
function swarmsData() {
  return {
    swarms: [],
    loading: true,

    async load() {
      this.loading = true;
      if (isDemo) {
        this.swarms = demoData.swarms;
      } else {
        const data = await api('GET', '/swarms');
        if (data.success) this.swarms = data.data;
      }
      this.loading = false;
    }
  };
}

// System component
function systemData() {
  return {
    verificationStats: null,
    loading: true,

    async load() {
      this.loading = true;
      if (isDemo) {
        this.verificationStats = demoData.verification;
      } else {
        const data = await api('GET', '/verification/stats');
        if (data.success) this.verificationStats = data.data;
      }
      this.loading = false;
    },

    async flush() { await api('POST', '/stats/flush'); },
    async hnrCheck() { await api('POST', '/hnr/check'); },
    async calcBonus() { await api('POST', '/bonus/calculate'); },
    async cleanupBans() { await api('POST', '/bans/cleanup'); },
    async clearCache() { await api('DELETE', '/verification/cache'); }
  };
}
