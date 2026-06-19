import { useEffect, useRef, useState } from 'react';
import {
  SafeAreaView, View, Text, TextInput, Pressable, ScrollView, Image,
  StyleSheet, StatusBar, Platform,
} from 'react-native';
import * as AudioStreamer from './modules/audio-streamer';
import type { StatsEvent, LogEvent } from './modules/audio-streamer';

const C = {
  bg: '#0a0b0f', card: '#14161d', card2: '#1b1e27', border: '#262a36',
  text: '#e8eaf0', dim: '#8b90a0', accent: '#6c8cff', good: '#00e0a4',
  warn: '#ffb347', bad: '#ff5a6e',
};

type LogLine = { id: number; t: string; message: string; level: string };

export default function App() {
  const [url, setUrl] = useState('ws://10.0.0.121:8080');
  const [bufferMs, setBufferMs] = useState(100);
  const [connected, setConnected] = useState(false);
  const [stats, setStats] = useState<StatsEvent | null>(null);
  const [artwork, setArtwork] = useState<string>('');
  const [logs, setLogs] = useState<LogLine[]>([]);
  const logId = useRef(0);
  const scroller = useRef<ScrollView>(null);
  const paused = !!stats?.paused;

  function addLog(message: string, level = 'info') {
    const t = new Date().toLocaleTimeString('es', { hour12: false });
    setLogs((prev) => {
      const next = [...prev, { id: logId.current++, t, message, level }];
      return next.length > 200 ? next.slice(next.length - 200) : next;
    });
  }

  useEffect(() => {
    const subStats = AudioStreamer.addStatsListener((e: StatsEvent) => {
      setStats(e);
      setConnected(e.connected);
    });
    const subLog = AudioStreamer.addLogListener((e: LogEvent) => addLog(e.message, e.level));
    const subArt = AudioStreamer.addArtworkListener((dataUri) => setArtwork(dataUri));
    addLog('Listo. Escribe la IP del PC y pulsa Conectar.', 'info');
    return () => { subStats.remove(); subLog.remove(); subArt.remove(); };
  }, []);

  function doConnect() {
    AudioStreamer.connect(url.trim(), bufferMs);
    setConnected(true);
  }
  function doDisconnect() {
    AudioStreamer.disconnect();
    setConnected(false);
    setStats(null);
    setArtwork('');
    addLog('Desconectado', 'info');
  }
  function togglePause() {
    if (paused) AudioStreamer.resume(); else AudioStreamer.pause();
  }

  function changeBuffer(delta: number) {
    const v = Math.max(40, Math.min(400, bufferMs + delta));
    setBufferMs(v);
    if (connected) AudioStreamer.setBufferMs(v);
  }

  const audioState = !connected ? '—'
    : !stats ? 'Conectando…'
    : paused ? 'Pausado'
    : !stats.flow ? 'Silencio (en pausa)'
    : stats.serverPeak < 0.001 ? 'Silencio'
    : stats.mutedPc ? 'Reproduciendo · PC mudo' : 'Reproduciendo';

  const dotColor = !connected ? C.bad : paused ? C.warn : (stats && stats.flow ? C.good : C.warn);

  return (
    <SafeAreaView style={st.root}>
      <StatusBar barStyle="light-content" />
      <ScrollView contentContainerStyle={st.scroll}>
        <View style={st.header}>
          <View style={st.titleRow}>
            <View style={[st.dot, { backgroundColor: dotColor }]} />
            <View>
              <Text style={st.title}>PC → Speaker</Text>
              <Text style={st.sub}>{connected ? (stats?.device || 'Conectado') : 'Desconectado'}</Text>
            </View>
          </View>
        </View>

        <View style={st.card}>
          <Text style={st.label}>Servidor</Text>
          <TextInput
            style={st.input}
            value={url}
            onChangeText={setUrl}
            editable={!connected}
            autoCapitalize="none"
            autoCorrect={false}
            keyboardType="url"
            placeholder="ws://192.168.1.50:8080"
            placeholderTextColor={C.dim}
          />
        </View>

        {!connected ? (
          <Pressable style={st.connect} onPress={doConnect}>
            <Text style={st.connectText}>▶  Conectar</Text>
          </Pressable>
        ) : (
          <View style={{ gap: 10 }}>
            <Pressable style={[st.connect, paused && st.connectResume]} onPress={togglePause}>
              <Text style={st.connectText}>{paused ? '▶  Reanudar' : '❙❙  Pausar'}</Text>
            </Pressable>
            <Pressable style={st.stopBtn} onPress={doDisconnect}>
              <Text style={st.stopBtnText}>■  Detener</Text>
            </Pressable>
          </View>
        )}

        {connected && (
          <View style={[st.card, st.npCard]}>
            {artwork ? (
              <Image source={{ uri: artwork }} style={st.npArt} />
            ) : (
              <View style={[st.npArt, st.npArtEmpty]}><Text style={st.npNote}>♪</Text></View>
            )}
            <View style={st.npText}>
              <Text style={st.npTitle} numberOfLines={2}>
                {stats?.npTitle ? stats.npTitle : 'Audio del PC'}
              </Text>
              <Text style={st.npSub} numberOfLines={1}>
                {stats?.npArtist || stats?.npApp || 'Sin información'}
              </Text>
            </View>
          </View>
        )}

        <View style={st.card}>
          <VU label="PC (origen)" value={stats?.serverPeak ?? 0} />
          <View style={{ height: 10 }} />
          <VU label="Teléfono" value={stats?.clientPeak ?? 0} />
        </View>

        <View style={st.card}>
          <View style={st.row}>
            <Text style={st.label}>Buffer / latencia</Text>
            <View style={st.stepper}>
              <Pressable style={st.stepBtn} onPress={() => changeBuffer(-10)}><Text style={st.stepTxt}>−</Text></Pressable>
              <Text style={st.stepVal}>{bufferMs} ms</Text>
              <Pressable style={st.stepBtn} onPress={() => changeBuffer(10)}><Text style={st.stepTxt}>＋</Text></Pressable>
            </View>
          </View>
        </View>

        <View style={st.grid}>
          <Stat k="Estado audio" v={audioState} color={connected && stats?.flow ? C.good : C.text} />
          <Stat k="Buffer actual" v={stats ? `${Math.round(stats.bufferMs)} ms` : '—'} />
          <Stat k="Bitrate" v={stats?.bitrateKbps ? `${stats.bitrateKbps} kbps` : '—'} />
          <Stat k="Underruns" v={`${stats?.underruns ?? 0}`} color={(stats?.underruns ?? 0) > 0 ? C.warn : C.text} />
        </View>

        <View style={st.card}>
          <View style={st.row}>
            <Text style={st.label}>Logs</Text>
            <Pressable onPress={() => setLogs([])}><Text style={st.clear}>limpiar</Text></Pressable>
          </View>
          <ScrollView
            ref={scroller}
            style={st.logBox}
            onContentSizeChange={() => scroller.current?.scrollToEnd({ animated: false })}
          >
            {logs.map((l) => (
              <Text key={l.id} style={st.logLine}>
                <Text style={st.logTime}>{l.t} </Text>
                <Text style={{ color: logColor(l.level) }}>{l.message}</Text>
              </Text>
            ))}
          </ScrollView>
        </View>

        <Text style={st.footer}>PCM 16-bit · 48 kHz · AVAudioEngine · background nativo</Text>
      </ScrollView>
    </SafeAreaView>
  );
}

function VU({ label, value }: { label: string; value: number }) {
  const pct = Math.max(0, Math.min(100, value * 140));
  return (
    <View style={st.vuRow}>
      <Text style={st.vuLabel}>{label}</Text>
      <View style={st.vuTrack}>
        <View style={[st.vuFill, { width: `${pct}%` }]} />
      </View>
    </View>
  );
}

function Stat({ k, v, color }: { k: string; v: string; color?: string }) {
  return (
    <View style={st.stat}>
      <Text style={st.statK}>{k}</Text>
      <Text style={[st.statV, color ? { color } : null]}>{v}</Text>
    </View>
  );
}

function logColor(level: string) {
  return level === 'ok' ? C.good : level === 'warn' ? C.warn : level === 'err' ? C.bad : C.text;
}

const st = StyleSheet.create({
  root: { flex: 1, backgroundColor: C.bg },
  scroll: { padding: 16, gap: 14, paddingTop: Platform.OS === 'android' ? 40 : 8 },
  header: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
  titleRow: { flexDirection: 'row', alignItems: 'center', gap: 10 },
  dot: { width: 11, height: 11, borderRadius: 6 },
  title: { color: C.text, fontSize: 18, fontWeight: '700' },
  sub: { color: C.dim, fontSize: 12 },
  card: { backgroundColor: C.card, borderColor: C.border, borderWidth: 1, borderRadius: 16, padding: 16 },
  label: { color: C.dim, fontSize: 12, textTransform: 'uppercase', letterSpacing: 0.5 },
  input: {
    marginTop: 8, backgroundColor: C.card2, borderRadius: 10, paddingHorizontal: 12,
    paddingVertical: 12, color: C.text, fontSize: 16,
  },
  connect: { backgroundColor: C.accent, borderRadius: 16, paddingVertical: 20, alignItems: 'center' },
  connectStop: { backgroundColor: C.bad },
  connectResume: { backgroundColor: C.good },
  connectText: { color: '#fff', fontSize: 18, fontWeight: '700' },
  stopBtn: { backgroundColor: C.card2, borderColor: C.border, borderWidth: 1, borderRadius: 14, paddingVertical: 12, alignItems: 'center' },
  stopBtnText: { color: C.bad, fontSize: 15, fontWeight: '700' },
  npCard: { flexDirection: 'row', alignItems: 'center', gap: 14 },
  npArt: { width: 56, height: 56, borderRadius: 10, backgroundColor: C.card2 },
  npArtEmpty: { alignItems: 'center', justifyContent: 'center' },
  npNote: { color: C.accent, fontSize: 28, fontWeight: '700' },
  npText: { flex: 1 },
  npTitle: { color: C.text, fontSize: 15, fontWeight: '700' },
  npSub: { color: C.dim, fontSize: 13, marginTop: 2 },
  row: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
  stepper: { flexDirection: 'row', alignItems: 'center', gap: 12 },
  stepBtn: { backgroundColor: C.card2, borderRadius: 8, width: 40, height: 36, alignItems: 'center', justifyContent: 'center' },
  stepTxt: { color: C.text, fontSize: 20, fontWeight: '700' },
  stepVal: { color: C.text, fontSize: 16, fontWeight: '700', minWidth: 64, textAlign: 'center' },
  vuRow: { flexDirection: 'row', alignItems: 'center', gap: 10 },
  vuLabel: { color: C.dim, fontSize: 11, width: 72 },
  vuTrack: { flex: 1, height: 8, backgroundColor: C.card2, borderRadius: 6, overflow: 'hidden' },
  vuFill: { height: 8, backgroundColor: C.good, borderRadius: 6 },
  grid: { flexDirection: 'row', flexWrap: 'wrap', gap: 10 },
  stat: { backgroundColor: C.card, borderColor: C.border, borderWidth: 1, borderRadius: 12, padding: 12, flexGrow: 1, flexBasis: '46%' },
  statK: { color: C.dim, fontSize: 11, textTransform: 'uppercase', letterSpacing: 0.4 },
  statV: { color: C.text, fontSize: 20, fontWeight: '700', marginTop: 4 },
  clear: { color: C.dim, fontSize: 12 },
  logBox: { height: 170, marginTop: 10, backgroundColor: '#07080b', borderRadius: 10, padding: 10 },
  logLine: { fontSize: 11, lineHeight: 17, fontFamily: Platform.OS === 'ios' ? 'Menlo' : 'monospace' },
  logTime: { color: '#555a68' },
  footer: { color: C.dim, fontSize: 11, textAlign: 'center', paddingVertical: 6 },
});
