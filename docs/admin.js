// b1tpoti0n Admin UI - Alpine.js version

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
    connected: false,

    async connect() {
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
      const data = await api('GET', '/stats');
      if (data.success) this.stats = data.data;
      this.loading = false;
    },
    async flush() { await api('POST', '/stats/flush'); },
    async hnrCheck() { await api('POST', '/hnr/check'); },
    async calcBonus() { await api('POST', '/bonus/calculate'); },
    async cleanupBans() { await api('POST', '/bans/cleanup'); }
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
      const data = await api('GET', '/users');
      if (data.success) this.users = data.data;
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
      const data = await api('GET', '/torrents');
      if (data.success) this.torrents = data.data;
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
      const data = await api('GET', '/whitelist');
      if (data.success) this.items = data.data;
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
      const path = activeOnly ? '/bans/active' : '/bans';
      const data = await api('GET', path);
      if (data.success) this.bans = data.data;
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
      const data = await api('GET', '/ratelimits');
      if (data.success) this.stats = data.data;
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
      const data = await api('GET', '/hnr');
      if (data.success) this.violations = data.data;
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
      const data = await api('GET', '/bonus/stats');
      if (data.success) this.stats = data.data;
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
      const data = await api('GET', '/swarms');
      if (data.success) this.swarms = data.data;
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
      const data = await api('GET', '/verification/stats');
      if (data.success) this.verificationStats = data.data;
      this.loading = false;
    },

    async flush() { await api('POST', '/stats/flush'); },
    async hnrCheck() { await api('POST', '/hnr/check'); },
    async calcBonus() { await api('POST', '/bonus/calculate'); },
    async cleanupBans() { await api('POST', '/bans/cleanup'); },
    async clearCache() { await api('DELETE', '/verification/cache'); }
  };
}
