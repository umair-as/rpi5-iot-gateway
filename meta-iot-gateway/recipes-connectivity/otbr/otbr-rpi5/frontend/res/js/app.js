/*
 *    Copyright (c) 2017, The OpenThread Authors.
 *    All rights reserved.
 *
 *    Redistribution and use in source and binary forms, with or without
 *    modification, are permitted provided that the following conditions are met:
 *    1. Redistributions of source code must retain the above copyright
 *       notice, this list of conditions and the following disclaimer.
 *    2. Redistributions in binary form must reproduce the above copyright
 *       notice, this list of conditions and the following disclaimer in the
 *       documentation and/or other materials provided with the distribution.
 *    3. Neither the name of the copyright holder nor the
 *       names of its contributors may be used to endorse or promote products
 *       derived from this software without specific prior written permission.
 *
 *    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 *    AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 *    IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 *    ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
 *    LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 *    CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 *    SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 *    INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 *    CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 *    ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 *    POSSIBILITY OF SUCH DAMAGE.
 *
 *    Rewritten for Alpine.js + D3 v7 — no AngularJS, MDL, or Angular Material
 */

document.addEventListener('alpine:init', () => {
    Alpine.data('appState', () => ({

        // ============================================
        // Theme
        // ============================================

        darkMode: false,
        showSecrets: false,

        // ============================================
        // Navigation
        // ============================================

        sidebarOpen: false,
        headerTitle: 'Dashboard',
        menu: [
            { title: 'Dashboard', icon: 'dashboard', show: true },
            { title: 'Join', icon: 'add_circle_outline', show: false },
            { title: 'Form', icon: 'open_in_new', show: false },
            { title: 'Status', icon: 'info_outline', show: false },
            { title: 'Settings', icon: 'settings', show: false },
            { title: 'Commission', icon: 'person_add', show: false },
            { title: 'Topology', icon: 'hub', show: false },
        ],

        // ============================================
        // Thread Configuration Defaults
        // ============================================

        thread: {
            networkName: 'IoTGW-Thread',
            extPanId: '',
            panId: '',
            passphrase: '',
            networkKey: '',
            channel: 15,
            prefix: 'fd11:22::',
            defaultRoute: true,
        },

        setting: {
            prefix: 'fd11:22::',
            defaultRoute: true,
        },

        commission: {
            pskd: '',
            passphrase: '',
        },

        // ============================================
        // Loading States
        // ============================================

        isLoading: false,
        isForming: false,
        isCommissioning: false,

        // ============================================
        // Network Data
        // ============================================

        networksInfo: [],
        status: [],

        // ============================================
        // Join Dialog State
        // ============================================

        joinThread: {
            credentialType: '',
            networkKey: '',
            pskd: '',
            prefix: 'fd11:22::',
            defaultRoute: true,
        },
        joinIsLoading: false,
        joinIndex: 0,
        qrImageSrc: '',

        // ============================================
        // Dialog State
        // ============================================

        alertTitle: '',
        alertMessage: '',
        confirmTitle: '',
        confirmMessage: '',
        _confirmResolve: null,

        // ============================================
        // Topology State
        // ============================================

        basicInfo: {
            networkName: 'Unknown',
            leaderData: { leaderRouterId: 'Unknown' },
        },
        numOfRouter: 'Unknown',
        nodeDetailInfo: 'Unknown',
        networksDiagInfo: '',
        graphIsReady: false,
        graphInfo: { nodes: [], links: [] },
        thresholdFrameErrorRate: 20,

        detailList: {
            extAddress:          { title: true,  content: true },
            rloc16:              { title: true,  content: true },
            ipv6Addresses:       { title: false, content: false },
            routerNeighbors:     { title: true,  content: false },
            route:               { title: true,  content: false },
            leaderData:          { title: false, content: false },
            networkData:         { title: false, content: true },
            macCounters:         { title: false, content: false },
            childTable:          { title: true,  content: false },
            channelPages:        { title: false, content: false },
            mode:                { title: false, content: false },
            timeout:             { title: false, content: false },
            connectivity:        { title: false, content: false },
            batteryLevel:        { title: false, content: false },
            supplyVoltage:       { title: false, content: false },
            maxChildTimeout:     { title: false, content: false },
            lDevIdSubject:       { title: false, content: false },
            iDevIdCert:          { title: false, content: false },
            eui64:               { title: false, content: false },
            version:             { title: false, content: false },
            vendorName:          { title: false, content: false },
            vendorModel:         { title: false, content: false },
            vendorSwVersion:     { title: false, content: false },
            threadStackVersion:  { title: false, content: false },
            children:            { title: false, content: false },
            childIpv6Addresses:  { title: false, content: false },
            mleCounters:         { title: false, content: false },
        },

        // ============================================
        // Internal (non-UI) State
        // ============================================

        _topologyGeneration: 0,
        _tooltip: null,
        _svgDrawn: undefined,
        _drawGraphTimer: null,
        _requestBody: {},

        // REST API base — in dev mode (nginx proxy on non-80 port), relative
        // URLs work. In production (port 80), need full URL with port 8081.
        get apiBase() {
            const port = location.port;
            const host = location.hostname;
            const scheme = location.protocol;
            return (port === '80' || port === '443' || port === '')
                ? scheme + '//' + host + ':8081'
                : '';
        },

        // ============================================
        // Initialization
        // ============================================

        init() {
            this.initTheme();
            this.watchSystemTheme();
        },

        // ============================================
        // Theme Management
        // ============================================

        initTheme() {
            var saved = localStorage.getItem('iotgw-theme');
            if (saved) {
                this.darkMode = (saved === 'dark');
            } else {
                this.darkMode = !!(window.matchMedia &&
                    window.matchMedia('(prefers-color-scheme: dark)').matches);
            }
            this.applyTheme();
        },

        applyTheme() {
            var theme = this.darkMode ? 'dark' : 'light';
            document.documentElement.setAttribute('data-theme', theme);
            localStorage.setItem('iotgw-theme', theme);
        },

        toggleTheme() {
            this.darkMode = !this.darkMode;
            this.applyTheme();
        },

        watchSystemTheme() {
            if (!window.matchMedia) return;
            var self = this;
            var mq = window.matchMedia('(prefers-color-scheme: dark)');
            var handler = function(e) {
                if (!localStorage.getItem('iotgw-theme')) {
                    self.darkMode = e.matches;
                    self.applyTheme();
                }
            };
            if (mq.addEventListener) {
                mq.addEventListener('change', handler);
            } else if (mq.addListener) {
                mq.addListener(handler);
            }
        },

        // ============================================
        // Navigation
        // ============================================

        async showPanels(index) {
            this.cancelTopologyOps();

            this.headerTitle = this.menu[index].title;
            for (var i = 0; i < this.menu.length; i++) {
                this.menu[i].show = false;
            }
            this.menu[index].show = true;

            // Join panel — scan for available networks
            if (index === 1) {
                await this.scanNetworks();
            }

            // Status panel — fetch device properties
            if (index === 3) {
                try {
                    var resp = await fetch('get_properties');
                    var data = await resp.json();
                    if (data.error === 0) {
                        var statusJson = data.result;
                        this.status = Object.keys(statusJson).map(function(key) {
                            return { name: key, value: statusJson[key] };
                        });
                    }
                } catch (err) {
                    console.warn('Failed to get properties:', err);
                }
            }

            // Topology panel — full async discovery + render pipeline
            if (index === 6) {
                var generation = this._topologyGeneration;
                this._svgDrawn = undefined;
                try {
                    await this.updateDeviceCollection(16, generation);
                    if (this.isTopologyCancelled(generation)) return;

                    await this.dataInit();
                    if (this.isTopologyCancelled(generation)) return;

                    await this.showTopology();
                } catch (err) {
                    console.error('Error loading topology:', err);
                }
            }
        },

        // ============================================
        // Network Scanning
        // ============================================

        async scanNetworks() {
            this.isLoading = true;
            this.networksInfo = [];
            try {
                var resp = await fetch('available_network');
                var data = await resp.json();
                if (data.error === 0) {
                    this.networksInfo = data.result;
                } else {
                    this.showAlert('Information',
                        'There is no available Thread network currently, please wait a moment and retry it.');
                }
            } catch (err) {
                console.warn('Failed to scan networks:', err);
                this.showAlert('Error', 'Failed to scan for networks.');
            }
            this.isLoading = false;
        },

        // ============================================
        // Status Grouping
        // ============================================

        get statusGroups() {
            var iconMap = {
                'IPv6': 'language',
                'Network': 'dns',
                'OpenThread': 'memory',
                'RCP': 'developer_board',
                'General': 'settings_ethernet',
            };
            var groups = {};
            for (var i = 0; i < this.status.length; i++) {
                var item = this.status[i];
                var colonIdx = item.name.indexOf(':');
                var group, label;
                if (colonIdx > 0) {
                    group = item.name.substring(0, colonIdx);
                    label = item.name.substring(colonIdx + 1);
                } else {
                    group = 'General';
                    label = item.name;
                }
                if (!groups[group]) {
                    groups[group] = { name: group, icon: iconMap[group] || 'info_outline', items: [] };
                }
                groups[group].items.push({ name: label, value: item.value });
            }
            return Object.values(groups);
        },

        // ============================================
        // Dialog System (native <dialog> elements)
        // ============================================

        showAlert(title, message) {
            this.alertTitle = title;
            this.alertMessage = message;
            this.$refs.alertDialog.showModal();
        },

        showConfirm(title, message) {
            var self = this;
            return new Promise(function(resolve) {
                self.confirmTitle = title;
                self.confirmMessage = message;
                self._confirmResolve = resolve;
                self.$refs.confirmDialog.showModal();
            });
        },

        confirmResolve() {
            this.$refs.confirmDialog.close();
            if (this._confirmResolve) {
                this._confirmResolve(true);
                this._confirmResolve = null;
            }
        },

        confirmReject() {
            this.$refs.confirmDialog.close();
            if (this._confirmResolve) {
                this._confirmResolve(false);
                this._confirmResolve = null;
            }
        },

        // ============================================
        // Join Network
        // ============================================

        openJoinDialog(idx, item) {
            this.joinIndex = idx;
            this.joinThread = {
                credentialType: '',
                networkKey: '00112233445566778899aabbccddeeff',
                pskd: '',
                prefix: 'fd11:22::',
                defaultRoute: true,
            };
            this.joinIsLoading = false;
            this.$refs.joinDialog.showModal();
        },

        async joinNetwork() {
            if (!this.joinThread.credentialType) return;

            this.joinIsLoading = true;
            var payload = {
                credentialType: this.joinThread.credentialType,
                networkKey: this.joinThread.networkKey,
                pskd: this.joinThread.pskd,
                prefix: this.joinThread.prefix,
                defaultRoute: this.joinThread.defaultRoute || false,
                index: this.joinIndex,
            };

            try {
                var resp = await fetch('join_network', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(payload),
                });
                var result = await resp.json();
                if (result.result === 'successful') {
                    this.$refs.joinDialog.close();
                }
                this.joinIsLoading = false;
                this.showAlert('Information',
                    'Join operation is ' + result.result + '. ' + (result.message || ''));
            } catch (err) {
                this.joinIsLoading = false;
                this.showAlert('Error', 'Failed to join network.');
            }
        },

        async generateQrCode() {
            try {
                var resp = await fetch('get_qrcode');
                var data = await resp.json();
                if (data.result === 'successful') {
                    var qrData = 'v=1&&eui=' + data.eui64 + '&&cc=' + this.joinThread.pskd;
                    var qr = qrcode(0, 'L');
                    qr.addData(qrData);
                    qr.make();
                    this.qrImageSrc = qr.createDataURL(4, 0);
                    this.$refs.qrDialog.showModal();
                } else {
                    this.showAlert('Information', 'Sorry, cannot generate the QR code.');
                }
            } catch (err) {
                this.showAlert('Error', 'Failed to get QR code data.');
            }
        },

        // ============================================
        // Form Network
        // ============================================

        async formNetwork() {
            var ok = await this.showConfirm('Form Network',
                'Are you sure you want to Form the Thread Network?');
            if (!ok) return;

            this.isForming = true;
            var payload = {
                networkKey: this.thread.networkKey,
                prefix: this.thread.prefix,
                defaultRoute: this.thread.defaultRoute || false,
                extPanId: this.thread.extPanId,
                panId: this.thread.panId,
                passphrase: this.thread.passphrase,
                channel: this.thread.channel,
                networkName: this.thread.networkName,
            };

            try {
                var resp = await fetch('form_network', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(payload),
                });
                var result = await resp.json();
                this.isForming = false;
                this.showAlert('Information', 'FORM operation is ' + result.result);
            } catch (err) {
                this.isForming = false;
                this.showAlert('Error', 'Failed to form network.');
            }
        },

        // ============================================
        // Settings — Add / Delete Prefix
        // ============================================

        async addPrefix() {
            var ok = await this.showConfirm('Add Prefix',
                'Are you sure you want to Add this On-Mesh Prefix?');
            if (!ok) return;

            var payload = {
                prefix: this.setting.prefix,
                defaultRoute: this.setting.defaultRoute || false,
            };

            try {
                var resp = await fetch('add_prefix', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(payload),
                });
                var result = await resp.json();
                this.showAlert('Information', 'Add operation is ' + result.result);
            } catch (err) {
                this.showAlert('Error', 'Failed to add prefix.');
            }
        },

        async deletePrefix() {
            var ok = await this.showConfirm('Delete Prefix',
                'Are you sure you want to Delete this On-Mesh Prefix?');
            if (!ok) return;

            var payload = {
                prefix: this.setting.prefix,
            };

            try {
                var resp = await fetch('delete_prefix', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(payload),
                });
                var result = await resp.json();
                this.showAlert('Information', 'Delete operation is ' + result.result);
            } catch (err) {
                this.showAlert('Error', 'Failed to delete prefix.');
            }
        },

        // ============================================
        // Commission
        // ============================================

        async startCommission() {
            this.isCommissioning = true;
            var payload = {
                pskd: this.commission.pskd,
                passphrase: this.commission.passphrase,
            };

            try {
                var resp = await fetch('commission', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(payload),
                });
                var result = await resp.json();
                if (result.error === 0) {
                    this.showAlert('Information', 'Commission operation is success');
                } else {
                    this.showAlert('Information', 'Commission operation is failed');
                }
            } catch (err) {
                this.showAlert('Error', 'Failed to commission.');
            }
            this.isCommissioning = false;
        },

        // ============================================
        // Topology — Cancellation & Concurrency
        // ============================================

        cancelTopologyOps() {
            this._topologyGeneration++;
            if (this._drawGraphTimer) {
                clearTimeout(this._drawGraphTimer);
                this._drawGraphTimer = null;
            }
        },

        isTopologyCancelled(gen) {
            return gen !== this._topologyGeneration;
        },

        // Bounded-concurrency async pool
        async asyncPool(poolLimit, items, iteratorFn) {
            var results = [];
            var executing = [];
            for (let i = 0; i < items.length; i++) {
                let p = Promise.resolve().then(function() {
                    return iteratorFn(items[i], i);
                });
                results.push(p);
                if (poolLimit <= items.length) {
                    let e = p.then(function() {
                        executing.splice(executing.indexOf(e), 1);
                    });
                    executing.push(e);
                    if (executing.length >= poolLimit) {
                        await Promise.race(executing);
                    }
                }
            }
            return Promise.all(results);
        },

        sleep(ms) {
            return new Promise(function(resolve) { setTimeout(resolve, ms); });
        },

        // ============================================
        // Utility Helpers
        // ============================================

        intToHexString(num, len) {
            var value = num.toString(16);
            while (value.length < len) {
                value = '0' + value;
            }
            return value;
        },

        isObject(obj) {
            return !!obj && obj.constructor === Object;
        },

        isArray(arr) {
            return !!arr && arr.constructor === Array;
        },

        getCSSVar(varName) {
            return getComputedStyle(document.documentElement).getPropertyValue(varName).trim();
        },

        // ============================================
        // Topology — REST API Request Bodies
        // ============================================

        _requestBodyUpdateDeviceCollectionDefault: {
            data: [{
                type: 'updateDeviceCollectionTask',
                attributes: { maxAge: 30, maxRetries: 5, deviceCount: 16, timeout: 15 },
            }],
        },

        _requestBodyDefault: {
            data: [{
                type: 'getNetworkDiagnosticTask',
                attributes: { destination: null, types: [], timeout: 10 },
            }],
        },

        createRequestBodyUpdateDeviceCollection(deviceCount) {
            var body = JSON.parse(JSON.stringify(this._requestBodyUpdateDeviceCollectionDefault));
            body.data[0].attributes.deviceCount = deviceCount;
            return body;
        },

        createRequestBody(destination) {
            var body = JSON.parse(JSON.stringify(this._requestBody));
            body.data[0].attributes.destination = destination;
            return body;
        },

        updateRequestBody() {
            this._requestBody = JSON.parse(JSON.stringify(this._requestBodyDefault));
            var self = this;
            Object.keys(this.detailList).forEach(function(key) {
                if (self.detailList[key].title === true) {
                    self._requestBody.data[0].attributes.types.push(key);
                }
            });
        },

        // ============================================
        // Topology — Async Discovery Pipeline
        // ============================================

        async getActionStatus(actionId) {
            try {
                var resp = await fetch(this.apiBase + '/api/actions/' + actionId, {
                    headers: { 'Accept': 'application/vnd.api+json' },
                });
                var data = await resp.json();
                return data && data.data && data.data.attributes
                    ? data.data.attributes.status
                    : undefined;
            } catch (err) {
                console.warn('Failed to get action status for id ' + actionId + ':', err);
                return undefined;
            }
        },

        // POST action to update device collection, then poll until complete
        async updateDeviceCollection(deviceCount, generation) {
            deviceCount = deviceCount || 16;
            var shouldRetry = false;
            var retries = 0;

            console.log('discover network ...');
            do {
                if (this.isTopologyCancelled(generation)) return;

                var postResp = await fetch(this.apiBase + '/api/actions', {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/vnd.api+json',
                        'Accept': 'application/vnd.api+json',
                    },
                    body: JSON.stringify(this.createRequestBodyUpdateDeviceCollection(deviceCount)),
                });
                var postData = await postResp.json();

                var actionId = postData && postData.data && postData.data[0]
                    ? postData.data[0].id
                    : undefined;
                console.log('action_id:', actionId);

                var time = 0.0;
                await this.sleep(200);
                shouldRetry = false;

                while (true) {
                    if (this.isTopologyCancelled(generation)) return;

                    var status = await this.getActionStatus(actionId);
                    if (status === 'completed') {
                        console.log('Completed action in %fs (id: %s)', time, actionId);
                        break;
                    }
                    if (status === 'stopped' || status === undefined) {
                        console.log('Oops... Action stopped (id: %s)', actionId);
                        retries++;
                        if (retries > 2) {
                            console.log('Exceed max retries, stop discovery');
                            shouldRetry = false;
                        } else {
                            console.log('Retry discovery ...');
                            shouldRetry = true;
                        }
                        break;
                    }
                    await this.sleep(500);
                    time += 0.5;
                }
            } while (shouldRetry);
        },

        // GET device collection
        async fetchDevices() {
            try {
                var resp = await fetch(this.apiBase + '/api/devices', {
                    headers: { 'Accept': 'application/json' },
                });
                var data = await resp.json();
                console.log('Devices:', data);
                return data;
            } catch (err) {
                console.warn('Get device collection failed:', err);
                return null;
            }
        },

        // POST to fetch device diagnostic, then poll until complete
        async fetchDeviceDiagnostic(deviceId) {
            var shouldRetry = false;
            var retries = 0;

            do {
                var postData;
                try {
                    var postResp = await fetch(this.apiBase + '/api/actions', {
                        method: 'POST',
                        headers: {
                            'Content-Type': 'application/vnd.api+json',
                            'Accept': 'application/vnd.api+json',
                        },
                        body: JSON.stringify(this.createRequestBody(deviceId)),
                    });
                    postData = await postResp.json();
                } catch (err) {
                    console.error('Error posting to actions endpoint:', err);
                    return;
                }

                var actionId = postData && postData.data && postData.data[0]
                    ? postData.data[0].id
                    : undefined;
                console.log('action_id:', actionId);

                var time = 0.0;
                await this.sleep(Math.random() * 250);
                shouldRetry = false;

                while (true) {
                    var status = await this.getActionStatus(actionId);
                    if (status === 'completed') {
                        console.log('Completed action in %fs (id: %s)', time, deviceId);
                        break;
                    }
                    if (status === 'stopped' || status === undefined) {
                        console.log('Oops... Action stopped (id: %s)', deviceId);
                        retries++;
                        if (retries > 2) {
                            console.log('Exceed max retries, stop diagnostic for: %s', deviceId);
                            shouldRetry = false;
                        } else {
                            console.log('Retry diagnostic for: %s', deviceId);
                            shouldRetry = true;
                        }
                        break;
                    }
                    await this.sleep(500);
                    time += 0.5;
                }
            } while (shouldRetry);
        },

        // Fetch diagnostics for all router devices with bounded concurrency
        async fetchDiagnosticsForDevices(devices, generation) {
            if (!devices || !Array.isArray(devices)) {
                console.warn('fetchDiagnosticsForDevices called with invalid devices list');
                return;
            }
            var nonChildDevices = devices.filter(function(d) { return d.role !== 'child'; });
            var self = this;

            await this.asyncPool(3, nonChildDevices, async function(device) {
                if (self.isTopologyCancelled(generation)) return;
                await self.fetchDeviceDiagnostic(device.extAddress);
            });
        },

        // Deduplicate diagnostic entries by extAddress, keeping newest
        dedupNetworksDiagEntries() {
            return Object.values(this.networksDiagInfo.reduce(function(acc, entry) {
                var extAddress = entry.extAddress;
                var createdDate = entry.created;
                if (!acc[extAddress] || new Date(createdDate) > new Date(acc[extAddress].created)) {
                    acc[extAddress] = entry;
                }
                return acc;
            }, {}));
        },

        // Fetch basic node info (network name, leader data, etc.)
        async dataInit() {
            try {
                var resp = await fetch(this.apiBase + '/api/node', {
                    headers: { 'Accept': 'application/json' },
                });
                var data = await resp.json();
                this.basicInfo = data;
                console.log(this.basicInfo.networkName);
                console.log(this.basicInfo.leaderData && this.basicInfo.leaderData.leaderRouterId);
                this.basicInfo.rloc16 = this.intToHexString(this.basicInfo.rloc16, 4);
                this.basicInfo.leaderData.leaderRouterId =
                    '0x' + this.intToHexString(this.basicInfo.leaderData.leaderRouterId, 2);
            } catch (err) {
                console.warn('Failed getting api/node:', err);
            }
        },

        // ============================================
        // Topology — Graph Operations
        // ============================================

        reloadGraph() {
            this.cancelTopologyOps();
            this._svgDrawn = undefined;
            this.showTopology();
        },

        async showTopology() {
            var generation = this._topologyGeneration;
            console.log('show topology...');

            this.graphIsReady = false;
            this.graphInfo = { nodes: [], links: [] };

            this.updateRequestBody();

            var devices = await this.fetchDevices();
            if (this.isTopologyCancelled(generation)) return;
            if (!devices || !Array.isArray(devices) || devices.length === 0) {
                console.warn('No devices available, skipping topology build.');
                this.graphIsReady = true;
                return;
            }

            // Delete stale diagnostics
            try {
                var delResp = await fetch(this.apiBase + '/api/diagnostics', { method: 'DELETE' });
                console.log('Deleted diagnostics status', delResp.status);
            } catch (err) {
                console.warn('Failed to delete diagnostics:', err);
            }
            if (this.isTopologyCancelled(generation)) return;

            // Fetch diagnostics for each router (max 3 concurrent)
            await this.fetchDiagnosticsForDevices(devices, generation);
            if (this.isTopologyCancelled(generation)) return;

            // Retrieve all collected diagnostics
            try {
                var getResp = await fetch(this.apiBase + '/api/diagnostics', {
                    headers: { 'Accept': 'application/json' },
                });
                this.networksDiagInfo = await getResp.json();
            } catch (err) {
                console.warn('Failed to get diagnostics:', err);
                this.graphIsReady = true;
                return;
            }
            if (this.isTopologyCancelled(generation)) return;

            console.log('networksDiagInfo:', this.networksDiagInfo);
            this.networksDiagInfo = this.dedupNetworksDiagEntries();
            console.log('networksDiagInfo after dedup:', this.networksDiagInfo);

            this.buildTopology();
            this.drawGraph();

            console.log('Graph rendered');
        },

        // Build graphInfo (nodes + links) from diagnostic data
        buildTopology() {
            var nodeMap = {};
            var count, src, dist, rloc, child, rlocOfParent, rlocOfChild, diagOfNode, linkNode, childInfo;

            // Normalize IDs to hex strings
            for (diagOfNode of this.networksDiagInfo) {
                if ('leaderData' in diagOfNode) {
                    if (diagOfNode.routerId === diagOfNode.leaderData.leaderRouterId) {
                        diagOfNode.isLeader = true;
                    }
                    diagOfNode.leaderData.leaderRouterId =
                        '0x' + this.intToHexString(diagOfNode.leaderData.leaderRouterId, 2);
                }
                diagOfNode.routerId = '0x' + this.intToHexString(diagOfNode.routerId, 2);

                if ('route' in diagOfNode) {
                    for (linkNode of diagOfNode.route.routeData) {
                        linkNode.routeId = '0x' + this.intToHexString(linkNode.routeId, 2);
                    }
                }
            }

            // Populate router nodes
            count = 0;
            for (diagOfNode of this.networksDiagInfo) {
                if ('childTable' in diagOfNode) {
                    rloc = diagOfNode.rloc16;
                    nodeMap[rloc] = count;

                    diagOfNode.role = diagOfNode.isLeader ? 'Leader' : 'Router';
                    this.graphInfo.nodes.push(diagOfNode);

                    if (diagOfNode.rloc16 === this.basicInfo.rloc16) {
                        this.nodeDetailInfo = diagOfNode;
                    }
                    count++;
                }
            }
            this.numOfRouter = count;

            // Construct links
            src = 0;
            for (diagOfNode of this.networksDiagInfo) {
                if ('childTable' in diagOfNode) {
                    // Router-to-router links
                    for (linkNode of diagOfNode.route.routeData) {
                        rloc = '0x' + (parseInt(linkNode.routeId, 16) << 10).toString(16).padStart(4, '0');
                        if (rloc in nodeMap) {
                            dist = nodeMap[rloc];
                            if (src < dist) {
                                this.graphInfo.links.push({
                                    source: src,
                                    target: dist,
                                    weight: 1,
                                    type: 0,
                                    linkInfo: {
                                        inQuality: linkNode.linkQualityIn,
                                        outQuality: linkNode.linkQualityOut,
                                    },
                                });
                            }
                        }
                    }

                    // Router-to-child links
                    for (childInfo of diagOfNode.childTable) {
                        child = {};
                        rlocOfParent = diagOfNode.rloc16;
                        rlocOfChild = (parseInt(diagOfNode.rloc16, 16) + childInfo.childId)
                            .toString(16).padStart(4, '0');

                        src = nodeMap[rlocOfParent];

                        child.rloc16 = '0x' + rlocOfChild;
                        child.routerId = diagOfNode.routerId;
                        nodeMap[rlocOfChild] = count;
                        child.role = 'Child';
                        this.graphInfo.nodes.push(child);
                        this.graphInfo.links.push({
                            source: src,
                            target: count,
                            weight: 1,
                            type: 1,
                            linkInfo: {
                                Timeout: childInfo.timeout,
                                Mode: childInfo.mode,
                            },
                        });
                        count++;
                    }
                }
                src++;
            }

            console.log('graphInfo:', this.graphInfo);
        },

        // Singleton D3 tooltip — created once, reused across redraws
        getOrCreateTooltip() {
            if (!this._tooltip || this._tooltip.empty()) {
                d3.selectAll('body > div.tooltip').remove();
                this._tooltip = d3.select('body')
                    .append('div')
                    .attr('class', 'tooltip')
                    .style('position', 'absolute')
                    .style('z-index', '10')
                    .style('visibility', 'hidden')
                    .text('');
            }
            return this._tooltip;
        },

        // Debounced drawGraph for slider — 250ms delay
        drawGraphDebounced() {
            var self = this;
            if (this._drawGraphTimer) {
                clearTimeout(this._drawGraphTimer);
            }
            this._drawGraphTimer = setTimeout(function() {
                self._drawGraphTimer = null;
                self.drawGraph();
            }, 250);
        },

        // ============================================
        // D3 v7 Graph Drawing (theme-aware)
        // ============================================

        drawGraph() {
            var self = this;
            var json = this.graphInfo;

            // Theme-aware colors from CSS custom properties
            var graphLeaderColor  = this.getCSSVar('--graph-leader')      || '#7e77f8';
            var graphRouterColor  = this.getCSSVar('--graph-router')      || '#03e2dd';
            var graphChildColor   = this.getCSSVar('--graph-child')       || '#aad4b0';
            var graphLinkColor    = this.getCSSVar('--graph-link')        || '#908484';
            var graphSelectedColor = this.getCSSVar('--graph-selected')   || '#f39191';
            var graphNodeStroke   = this.getCSSVar('--graph-node-stroke') || '#484e46';
            var textColor         = this.getCSSVar('--text-primary')      || '#212121';

            console.log('D3: updating SVG');

            var container = document.getElementById('topograph');
            if (!container) return;
            container.innerHTML = '';

            var scale = json.nodes.length;
            var len = 50 * Math.sqrt(scale) + 200;

            // ---- Legend SVG ----
            var svgLegend = d3.select('.d3graph').append('svg')
                .attr('preserveAspectRatio', 'xMidYMid meet')
                .attr('viewBox', '0 0 ' + len + ' ' + (len / 7));

            var sl = len / 250; // legend scale factor

            svgLegend.append('circle')
                .attr('cx', len - 20 * sl).attr('cy', 10 * sl).attr('r', 3 * sl)
                .style('fill', graphLeaderColor)
                .style('stroke', graphNodeStroke).style('stroke-width', '0.4px');

            svgLegend.append('circle')
                .attr('cx', len - 20 * sl).attr('cy', 20 * sl).attr('r', 3 * sl)
                .style('fill', graphRouterColor)
                .style('stroke', graphNodeStroke).style('stroke-width', '0.4px');

            svgLegend.append('circle')
                .attr('cx', len - 20 * sl).attr('cy', 30 * sl).attr('r', 3 * sl)
                .style('fill', graphChildColor)
                .style('stroke', graphNodeStroke).style('stroke-width', '0.4px')
                .style('stroke-dasharray', '2 1');

            svgLegend.append('circle')
                .attr('cx', len - 50 * sl).attr('cy', 10 * sl).attr('r', 3 * sl)
                .style('fill', '#ffffff')
                .style('stroke', graphSelectedColor).style('stroke-width', '0.4px');

            svgLegend.append('text')
                .attr('x', len - 15 * sl).attr('y', 10 * sl)
                .text('Leader').style('font-size', (4 * sl) + 'px')
                .style('fill', textColor).attr('alignment-baseline', 'middle');

            svgLegend.append('text')
                .attr('x', len - 15 * sl).attr('y', 20 * sl)
                .text('Router').style('font-size', (4 * sl) + 'px')
                .style('fill', textColor).attr('alignment-baseline', 'middle');

            svgLegend.append('text')
                .attr('x', len - 15 * sl).attr('y', 30 * sl)
                .text('Child').style('font-size', (4 * sl) + 'px')
                .style('fill', textColor).attr('alignment-baseline', 'middle');

            svgLegend.append('text')
                .attr('x', len - 45 * sl).attr('y', 10 * sl)
                .text('Selected').style('font-size', (4 * sl) + 'px')
                .style('fill', textColor).attr('alignment-baseline', 'middle');

            // ---- Zoom behavior (D3 v7) ----
            var svgGroup; // the <g> that gets transformed by zoom

            var zoom = d3.zoom()
                .scaleExtent([0.5, 3])
                .on('zoom', function(event) {
                    svgGroup.attr('transform', event.transform);
                });

            // ---- Main topology SVG ----
            var svgRoot = d3.select('.d3graph').append('svg')
                .attr('preserveAspectRatio', 'xMidYMid meet')
                .attr('viewBox', '0 0 ' + len + ' ' + len)
                .call(zoom);

            svgGroup = svgRoot.append('g');

            // Reuse singleton tooltip
            var tooltip = this.getOrCreateTooltip();
            tooltip.style('visibility', 'hidden').text('');

            // ---- Force simulation (D3 v7) ----
            var simulation = d3.forceSimulation(json.nodes)
                .force('link', d3.forceLink(json.links)
                    .distance(function(link) {
                        return link.type
                            ? 50
                            : (link.linkInfo.inQuality ? 100 / link.linkInfo.inQuality + 50 : 250);
                    })
                    .strength(0.5))
                .force('charge', d3.forceManyBody().strength(-50))
                .force('center', d3.forceCenter(len / 2, len / 2));

            // ---- Color scale for error rate ----
            var colorScale = d3.scaleLinear()
                .domain([0, 0.5, 0.75, 1])
                .range(['green', 'yellow', 'orange', 'red']);

            // ---- Links ----
            var link = svgGroup.selectAll('.link')
                .data(json.links)
                .enter().append('line')
                .attr('class', 'link')
                .style('stroke', function(item) {
                    var target = item.source && item.source.routerNeighbors
                        ? item.source.routerNeighbors.find(function(n) {
                            return n.rloc16 === (item.target.rloc16 || item.target);
                        })
                        : null;
                    if (target && target.frameErrorRate >= self.thresholdFrameErrorRate / 100) {
                        return colorScale(target.frameErrorRate);
                    }
                    return graphLinkColor;
                })
                .style('stroke-dasharray', function(item) {
                    return ('Timeout' in item.linkInfo) ? '4 4' : '0 0';
                })
                .style('stroke-width', function(item) {
                    return ('inQuality' in item.linkInfo)
                        ? Math.sqrt(item.linkInfo.inQuality)
                        : 1;
                })
                .on('mouseover', function(event, item) {
                    tooltip.style('visibility', 'visible')
                        .text(JSON.stringify(item.linkInfo));
                })
                .on('mousemove', function(event) {
                    tooltip.style('top', (event.pageY - 10) + 'px')
                        .style('left', (event.pageX + 10) + 'px');
                })
                .on('mouseout', function() {
                    tooltip.style('visibility', 'hidden');
                });

            // ---- Drag behavior (D3 v7) ----
            var drag = d3.drag()
                .on('start', function(event, d) {
                    if (!event.active) simulation.alphaTarget(0.3).restart();
                    d.fx = d.x;
                    d.fy = d.y;
                })
                .on('drag', function(event, d) {
                    d.fx = event.x;
                    d.fy = event.y;
                })
                .on('end', function(event, d) {
                    if (!event.active) simulation.alphaTarget(0);
                    d.fx = null;
                    d.fy = null;
                });

            // ---- Nodes ----
            var node = svgGroup.selectAll('.node')
                .data(json.nodes)
                .enter().append('g')
                .attr('class', function(item) { return item.role; })
                .call(drag)
                .on('mouseover', function(event, item) {
                    tooltip.style('visibility', 'visible').text(item.rloc16);
                })
                .on('mousemove', function(event) {
                    tooltip.style('top', (event.pageY - 10) + 'px')
                        .style('left', (event.pageX + 10) + 'px');
                })
                .on('mouseout', function() {
                    tooltip.style('visibility', 'hidden');
                });

            // ---- Child circles ----
            d3.selectAll('.Child')
                .append('circle')
                .attr('r', '6')
                .attr('fill', graphChildColor)
                .style('stroke', graphNodeStroke)
                .style('stroke-dasharray', '2 1')
                .style('stroke-width', '0.5px')
                .attr('class', function(item) { return item.rloc16; })
                .on('mouseover', function(event, item) {
                    tooltip.style('visibility', 'visible').text(item.rloc16);
                })
                .on('mousemove', function(event) {
                    tooltip.style('top', (event.pageY - 10) + 'px')
                        .style('left', (event.pageX + 10) + 'px');
                })
                .on('mouseout', function() {
                    tooltip.style('visibility', 'hidden');
                });

            // ---- Leader circles ----
            d3.selectAll('.Leader')
                .append('circle')
                .attr('r', '8')
                .attr('fill', graphLeaderColor)
                .style('stroke', graphNodeStroke)
                .style('stroke-width', '1px')
                .attr('class', 'Stroke')
                .on('mouseover', function(event, item) {
                    d3.select(this).transition().attr('r', '9');
                    tooltip.style('visibility', 'visible').text(item.rloc16);
                })
                .on('mousemove', function(event) {
                    tooltip.style('top', (event.pageY - 10) + 'px')
                        .style('left', (event.pageX + 10) + 'px');
                })
                .on('mouseout', function(event, item) {
                    d3.select(this).transition().attr('r', '8');
                    tooltip.style('visibility', 'hidden');
                })
                .on('click', function(event, item) {
                    d3.selectAll('.Stroke')
                        .style('stroke', graphNodeStroke)
                        .style('stroke-width', '1px');
                    d3.select(this)
                        .style('stroke', graphSelectedColor)
                        .style('stroke-width', '1px');
                    self.nodeDetailInfo = item;
                });

            // ---- Router circles ----
            d3.selectAll('.Router')
                .append('circle')
                .attr('r', '8')
                .style('stroke', graphNodeStroke)
                .style('stroke-width', '1px')
                .attr('fill', graphRouterColor)
                .attr('class', 'Stroke')
                .on('mouseover', function(event, item) {
                    d3.select(this).transition().attr('r', '8');
                    tooltip.style('visibility', 'visible').text(item.rloc16);
                })
                .on('mousemove', function(event) {
                    tooltip.style('top', (event.pageY - 10) + 'px')
                        .style('left', (event.pageX + 10) + 'px');
                })
                .on('mouseout', function(event, item) {
                    d3.select(this).transition().attr('r', '7');
                    tooltip.style('visibility', 'hidden');
                })
                .on('click', function(event, item) {
                    d3.selectAll('.Stroke')
                        .style('stroke', graphNodeStroke)
                        .style('stroke-width', '1px');
                    d3.select(this)
                        .style('stroke', graphSelectedColor)
                        .style('stroke-width', '1px');
                    self.nodeDetailInfo = item;
                });

            // ---- Tick handler — update positions each frame ----
            simulation.on('tick', function() {
                link
                    .attr('x1', function(d) { return d.source.x; })
                    .attr('y1', function(d) { return d.source.y; })
                    .attr('x2', function(d) { return d.target.x; })
                    .attr('y2', function(d) { return d.target.y; });

                node.attr('transform', function(d) {
                    return 'translate(' + d.x + ',' + d.y + ')';
                });
            });

            this.graphIsReady = true;
        },

    }));
});
