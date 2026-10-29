// netsong.scd - the network, played by an imaginary studio
// (Floating Points x Four Tet x Aphex Twin x Bonobo).
//
// No backing track: every sound is a packet. Each packet gets a random
// instrument, gesture and stereo spot, so nothing repeats. Everything shares
// a slowly drifting jazzy key so the randomness always sounds deliberate.
//
// Instruments (SuperCollider models, plus samples that are not in this repo):
//   Buchla        complex oscillator + wavefolder + low-pass gate "bongos"
//   ARP 2600      ring-modded, resonant, sample-and-hold runs
//   OB-8 / OB-Xa  fat detuned brassy chord swells
//   CS-70M / Reface CS   soft analogue leads
//   Therevox      gliding theremin-ish swoops
//   Tenori-On     soft bleep runs
//   Moog Sub 37   fat ladder-filter bass          (Bonobo)
//   Prophet-6     warm drifting poly chords       (Bonobo)
//   MicroFreak    weird digital oscillators       (Bonobo)
//   ES-335        modelled jazz guitar            (Bonobo)
//   Jazz Bass     modelled plucked bass           (Bonobo)
//   Fender Rhodes, harp  (real samples)
//   Lunar drums   chopped, pitched and reversed percussion (Pulsar-23 vibes)
//   Glitches      stuttered, bit-crushed sample fragments
// Effects: Binson Echorec-style multi-head echo, reverb, SP-303-style lo-fi glue.
//
// Started by netsong-audio.sh (the netsong systemd service).

(
"SC_JACK_DEFAULT_OUTPUTS".setenv("system:playback_1,system:playback_2");
s = Server.default;
s.options.numOutputBusChannels = 2;
s.options.numInputBusChannels = 0;
s.options.memSize = 65536;
s.options.numBuffers = 2048;
s.latency = 0.2;

s.waitForBoot {

    // ------------------------------------------------------------ settings
    ~root = "NETSONG_DIR".getenv ? "~".standardizePath;
    ~bpm = ("NETSONG_BPM".getenv ? "124").asFloat;
    ~busy = ("NETSONG_BUSY".getenv ? "2.5").asFloat;
    ~verbose = "NETSONG_VERBOSE".getenv == "1";
    ~stepDur = 60 / ~bpm / 4;
    ~swing = 0.2;

    // ------------------------------------------------------------- harmony
    // A ring of related jazzy keys; the music drifts one step at a time.
    ~keys = [
        ["Am9",       [9, 0, 4, 7, 11]],
        ["Fmaj9#11",  [5, 9, 0, 4, 7, 11]],
        ["Dm11",      [2, 5, 9, 0, 4, 7]],
        ["Bbmaj9",    [10, 2, 5, 9, 0]],
        ["Gm9",       [7, 10, 2, 5, 9]],
        ["Cm11",      [0, 3, 7, 10, 2, 5]],
        ["Ebmaj9",    [3, 7, 10, 2, 5]],
        ["Abmaj9#11", [8, 0, 3, 7, 10, 2]]
    ];
    ~keyIdx = 1;
    ~pool = { |lo, hi| var pcs = ~keys[~keyIdx][1]; (lo..hi).select { |n| pcs.includes(n % 12) } };
    ~drift = { |why|
        ~keyIdx = (~keyIdx + [-1, 1].choose).wrap(0, ~keys.size - 1);
        ("~~~ " ++ why ++ " - key drifts to " ++ ~keys[~keyIdx][0]).postln;
    };

    // "A#1" / "EB4" -> MIDI note number (C4 = 60)
    ~noteNum = { |str|
        var t = str.toLower, letters = (c: 0, d: 2, e: 4, f: 5, g: 7, a: 9, b: 11);
        var pc = letters[t[0].asString.asSymbol], i = 1, acc = 0, oct;
        if(t.size > 1 and: { t[1] == $# }) { acc = 1; i = 2 } {
            if(t.size > 1 and: { t[1] == $b }) { acc = -1; i = 2 } };
        oct = if(t.size > i) { t.copyToEnd(i).asInteger } { 4 };
        pc + acc + ((oct + 1) * 12)
    };

    // ------------------------------------------------------ buses & groups
    ~dryBus = Bus.audio(s, 2);
    ~revBus = Bus.audio(s, 2);
    ~echoBus = Bus.audio(s, 2);
    ~srcGroup = Group.new(s);
    ~fxGroup = Group.after(~srcGroup);

    ~route = { |sig|
        var rev = \rev.kr(0.2), echo = \echo.kr(0.3);
        Out.ar(~dryBus.index, sig);
        Out.ar(~revBus.index, sig * rev);
        Out.ar(~echoBus.index, sig * echo);
    };

    // ---------------------------------------------------------- the gear
    // Buchla: FM complex oscillator -> wavefolder -> low-pass gate
    SynthDef(\buchla, { |freq = 440, amp = 0.2, pan = 0, ratio = 2, index = 2, fold = 2, decay = 0.4|
        var env = EnvGen.ar(Env.perc(0.001, decay, 1, -6), doneAction: 2);
        var sig = SinOsc.ar(freq, SinOsc.ar(freq * ratio) * index * env);
        sig = (sig * (1 + (fold * env))).fold2(1);
        sig = LPF.ar(sig, ((env * 9000) + 80).clip(80, 16000)) * env;
        ~route.(Pan2.ar(sig, pan, amp));
    }).add;

    // ARP 2600: saw + pulse, ring mod, screaming resonant filter
    SynthDef(\arp2600, { |freq = 220, amp = 0.2, pan = 0, ring = 1.5, res = 0.15, decay = 0.25, noise = 0|
        var env = EnvGen.ar(Env.perc(0.002, decay, 1, -4), doneAction: 2);
        var osc = Saw.ar(freq) + Pulse.ar(freq * 1.002, 0.3);
        var sig = (osc * SinOsc.ar(freq * ring) * 0.7) + (osc * 0.3) + (WhiteNoise.ar * noise);
        sig = RLPF.ar(sig, ((freq * 2) + (env * freq * 12)).clip(40, 15000), res);
        sig = (sig * 1.5).tanh * env * 0.4;
        ~route.(Pan2.ar(sig, pan, amp));
    }).add;

    // OB-8 / OB-Xa: four-note detuned saw + pulse chord with a brassy filter swell
    SynthDef(\obx, { |amp = 0.12, pan = 0, att = 0.4, dur = 2, notes = #[60, 64, 67, 71]|
        var f = notes.midicps;
        var env = EnvGen.ar(Env([0, 1, 0.8, 0], [att, dur, 1.5], [2, 0, -3]), doneAction: 2);
        var fenv = EnvGen.ar(Env([0.3, 1, 0.5], [att * 0.8, dur], -2));
        var l = Mix(Saw.ar(f * 0.997)) + Mix(Pulse.ar(f * 1.003, 0.4));
        var r = Mix(Saw.ar(f * 1.004)) + Mix(Pulse.ar(f * 0.996, 0.45));
        var sig = MoogFF.ar([l, r] * 0.08, (fenv * 3500).clip(200, 8000), 1.2) * env;
        ~route.(Balance2.ar(sig[0], sig[1], pan, amp));
    }).add;

    // CS-70M / Reface CS: soft analogue lead with a gentle filter pluck
    SynthDef(\cs, { |freq = 440, amp = 0.2, pan = 0, decay = 0.6, cut = 3|
        var env = EnvGen.ar(Env.perc(0.01, decay, 1, -3), doneAction: 2);
        var vib = SinOsc.kr(5.5, 0, 0.003, 1);
        var sig = VarSaw.ar(freq * vib, 0, 0.4) + (SinOsc.ar(freq / 2) * 0.4);
        sig = MoogFF.ar(sig, (freq * cut * (0.4 + env)).clip(100, 12000), 2) * env;
        ~route.(Pan2.ar(sig, pan, amp));
    }).add;

    // Therevox: gliding, vibrato-laden swoop between two notes
    SynthDef(\therevox, { |freq = 440, freq2 = 660, amp = 0.15, pan = 0, glide = 0.6, dur = 1.5|
        var env = EnvGen.ar(Env([0, 1, 1, 0], [0.08, dur, 0.6], [2, 0, -3]), doneAction: 2);
        var pitch = XLine.kr(freq, freq2, glide) * SinOsc.kr(6, 0, 0.006, 1);
        var sig = SinOsc.ar(pitch) + (LFTri.ar(pitch * 2) * 0.15);
        sig = LPF.ar(sig, 3000) * env;
        ~route.(Pan2.ar(sig, pan, amp));
    }).add;

    // Tenori-On: soft little bleep
    SynthDef(\tenori, { |freq = 880, amp = 0.15, pan = 0|
        var env = EnvGen.ar(Env.perc(0.001, 0.18, 1, -5), doneAction: 2);
        var sig = SinOsc.ar(freq) + (Pulse.ar(freq, 0.5) * 0.08);
        sig = LPF.ar(sig, 5000) * env;
        ~route.(Pan2.ar(sig, pan, amp));
    }).add;

    // Moog Sub 37: two saws + sub square into a driven ladder filter
    SynthDef(\sub37, { |freq = 110, amp = 0.3, pan = 0, decay = 0.5, cut = 4, drive = 2|
        var env = EnvGen.ar(Env.perc(0.005, decay, 1, -3), doneAction: 2);
        var fenv = EnvGen.ar(Env.perc(0.001, decay * 0.6, 1, -4));
        var sig = Saw.ar(freq) + Saw.ar(freq * 1.004) + (Pulse.ar(freq / 2, 0.5) * 0.6);
        sig = MoogFF.ar(sig * 0.3, (freq * (1 + (fenv * cut))).clip(40, 12000), 2.8);
        sig = (sig * drive).tanh * env * 0.6;
        ~route.(Pan2.ar(sig, pan, amp));
    }).add;

    // Prophet-6: four drifting VCO voices, filter swell, chorus width
    SynthDef(\prophet, { |amp = 0.1, pan = 0, att = 0.1, dur = 1.5, cut = 2500, notes = #[60, 64, 67, 71]|
        var f = notes.midicps;
        var env = EnvGen.ar(Env([0, 1, 0.7, 0], [att, dur, 1.2], [1, 0, -3]), doneAction: 2);
        var fenv = EnvGen.ar(Env([0.2, 1, 0.4], [att, dur], -3));
        var drift = { LFNoise1.kr(0.4).range(0.994, 1.006) } ! 4;
        var sig = Mix(Saw.ar(f * drift)) + Mix(Pulse.ar(f * drift.reverse, 0.35));
        sig = MoogFF.ar(sig * 0.08, (fenv * cut).clip(150, 9000), 1.6) * env;
        sig = [sig, DelayC.ar(sig, 0.02, LFNoise1.kr(0.3).range(0.005, 0.015))];
        ~route.(Balance2.ar(sig[0], sig[1], pan, amp));
    }).add;

    // MicroFreak: PWM / formant / FM digital modes with a pitch blip and sample-rate grit
    SynthDef(\microfreak, { |freq = 440, amp = 0.15, pan = 0, mode = 0, decay = 0.3|
        var env = EnvGen.ar(Env.perc(0.001, decay, 1, -5), doneAction: 2);
        var pitch = freq * (1 + (EnvGen.ar(Env.perc(0, 0.03)) * 1.5));
        var sig = Select.ar(mode, [
            Pulse.ar(pitch, SinOsc.kr(12).range(0.1, 0.9)),
            Formant.ar(pitch, pitch * LFNoise0.kr(8).range(2, 6), pitch * 1.5),
            SinOsc.ar(pitch, SinOsc.ar(pitch * 3.7) * 4 * env)
        ]);
        sig = Latch.ar(sig, Impulse.ar(LFNoise0.kr(6).range(6000, 22000)));
        sig = RLPF.ar(sig, (pitch * 6).clip(200, 14000), 0.4) * env;
        ~route.(Pan2.ar(sig, pan, amp * 0.5));
    }).add;

    // Gibson ES-335: plucked string with hollow-body resonances
    SynthDef(\es335, { |freq = 220, amp = 0.3, pan = 0|
        var exc = LPF.ar(WhiteNoise.ar, 2500) * EnvGen.ar(Env.perc(0.001, 0.01));
        var sig = Pluck.ar(exc, Impulse.ar(0), 0.05, freq.reciprocal, 3, 0.4);
        sig = sig + (BPF.ar(sig, 180, 0.6) * 1.5) + (BPF.ar(sig, 420, 0.8) * 0.8);
        sig = LPF.ar((sig * 1.5).tanh, 3200) * EnvGen.ar(Env([1, 1, 0], [3, 0.3]), doneAction: 2);
        ~route.(Pan2.ar(sig, pan, amp));
    }).add;

    // Fender Jazz Bass: plucked string with a thumpy sine underneath
    SynthDef(\jazzbass, { |freq = 55, amp = 0.4, pan = 0, decay = 1.5|
        var exc = LPF.ar(WhiteNoise.ar, 1200) * EnvGen.ar(Env.perc(0.001, 0.02));
        var sig = Pluck.ar(exc, Impulse.ar(0), 0.05, freq.reciprocal, decay * 2, 0.6);
        sig = sig + (SinOsc.ar(freq) * EnvGen.ar(Env.perc(0.005, decay)) * 0.5);
        sig = LPF.ar(sig, 1200) * EnvGen.ar(Env([1, 1, 0], [decay, 0.1]), doneAction: 2);
        ~route.(Pan2.ar(sig, pan, amp));
    }).add;

    // sample player (forwards or reversed) and glitch stutterer, mono and stereo versions
    [1, 2].do { |n|
        SynthDef(("samp" ++ n).asSymbol, { |buf, rate = 1, amp = 0.3, pan = 0, rel = 10, back = 0|
            var frames = BufFrames.kr(buf);
            var sig = PlayBuf.ar(n, buf, rate * BufRateScale.kr(buf) * (1 - (2 * back)), 1,
                                 back * (frames - 2), doneAction: 2);
            sig = sig * EnvGen.ar(Env([1, 1, 0], [rel, 0.3]), doneAction: 2);
            sig = if(n == 2) { Balance2.ar(sig[0], sig[1], pan, amp) } { Pan2.ar(sig, pan, amp) };
            ~route.(sig);
        }).add;

        SynthDef(("crush" ++ n).asSymbol, { |buf, rate = 1, start = 0, len = 0.06, reps = 4,
                                             amp = 0.25, pan = 0, srate = 8000, bits = 8|
            var sig = PlayBuf.ar(n, buf, rate * BufRateScale.kr(buf), Impulse.ar(len.reciprocal),
                                 start * BufFrames.kr(buf));
            sig = Latch.ar(sig, Impulse.ar(srate));
            sig = (sig * (2 ** bits)).round(1) / (2 ** bits);
            sig = sig * EnvGen.ar(Env([1, 1, 0], [len * reps, 0.01]), doneAction: 2);
            sig = if(n == 2) { Balance2.ar(sig[0], sig[1], pan, amp) } { Pan2.ar(sig, pan, amp) };
            ~route.(sig);
        }).add;
    };

    // Master: Echorec-style four-head echo, reverb, SP-303-style glue
    SynthDef(\master, { |amp = 0.8, head = 0.38, feedback = 0.38|
        var dry = In.ar(~dryBus.index, 2);
        var revIn = In.ar(~revBus.index, 2);
        var echoIn = In.ar(~echoBus.index, 2);
        var fb, drum, echo, rev, mix;

        fb = LocalIn.ar(2);
        drum = echoIn + (fb * feedback);
        echo = [0.6, 0.3, 0.4, 0.2].collect { |w, i|
            var d = DelayC.ar(drum, 3, (head * (i + 1)) + (LFNoise2.kr(0.3 + (i * 0.1)) * 0.002)) * w;
            if(i.odd) { d.reverse } { d }                 // alternate heads bounce across the stereo field
        }.sum;
        echo = LPF.ar(HPF.ar(echo, 200), 3200);
        echo = (echo * 1.3).tanh / 1.3;                   // worn tape saturation
        LocalOut.ar(echo);

        rev = FreeVerb2.ar(revIn[0] + (echo[0] * 0.25), revIn[1] + (echo[1] * 0.25), 1, 0.9, 0.5);
        mix = dry + echo + (rev * 0.8);
        mix = Compander.ar(mix, mix, 0.4, 1, 0.5, 0.01, 0.2);
        mix = DelayC.ar(mix, 0.02, 0.005 + (LFNoise2.kr(0.5) * 0.0006) + (SinOsc.kr(5.5) * 0.00006));  // tape wow & flutter
        mix = (mix * 0.85) + (Latch.ar((mix * 256).round(1) / 256, Impulse.ar(18000)) * 0.15);        // old-sampler crunch
        mix = LPF.ar((mix * 1.5).tanh, 11000);
        mix = Limiter.ar(LeakDC.ar(mix) * amp, 0.95);
        Out.ar(0, mix);
    }).add;

    // -------------------------------------------------------- load samples
    ~loadDir = { |name|
        var paths = (~root +/+ "samples" +/+ name +/+ "*.wav").pathMatch.sort;
        if(paths.isEmpty) { ("(no samples in samples/" ++ name ++ ")").postln };
        paths.collect { |p| [p, Buffer.read(s, p)] }
    };
    ~rhodes = ~loadDir.("rhodes").collect { |e|
        [~noteNum.(e[0].basename.splitext[0].split($-).last), e[1]] }.sort { |a, b| a[0] < b[0] };
    ~harp = ~loadDir.("harp").collect { |e|
        [~noteNum.(e[0].basename.split($_)[2]), e[1]] }.sort { |a, b| a[0] < b[0] };
    ~perc = [\kick, \snare, \clap, \rim, \hat, \ohat, \ride, '808'].collect { |d|
        ~loadDir.(d.asString).collect { |e| e[1] } }.flat;

    s.sync;
    ~glitchSrc = ~perc ++ ~rhodes.collect { |e| e[1] } ++ ~harp.collect { |e| e[1] };
    ~master = Synth(\master, [\head, ~stepDur * 3], ~fxGroup);

    // ------------------------------------------------------------ helpers
    // ------------------------------------------------ sound -> visuals (optional)
    // Every sound goes through ~play, so this is the one place that tells the visualiser
    // on milk what was played: pitch, loudness, how long it lasts and which device caused it.
    // Sends to milk (192.168.1.10) unless NETSONG_VIZ names another address, or is "off".
    ~vizIp = "NETSONG_VIZ".getenv ? "192.168.1.10";
    ~vizAddr = if(~vizIp != "off" and: { ~vizIp.size > 0 }) { NetAddr(~vizIp, 5005) };
    ~vizRef = (buchla: 0.22, arp2600: 0.2, cs: 0.2, tenori: 0.15, sub37: 0.35, jazzbass: 0.45,
               microfreak: 0.3, es335: 0.35, obx: 0.1, prophet: 0.1, therevox: 0.15,
               samp1: 0.4, samp2: 0.4, crush1: 0.25, crush2: 0.25);

    ~vizBufDur = { |b| if(b.numFrames.notNil and: { b.sampleRate.notNil }) { b.numFrames / b.sampleRate } { 4 } };

    ~vizSend = { |def, args, offset|
        var a, note, dur, vel, ty, mac, inst;
        if(~vizAddr.notNil) {
            a = Dictionary.newFrom(args);
            note = if(a[\freq].notNil) { a[\freq].cpsmidi } {
                if(a[\notes].notNil) { a[\notes].mean } { ~vizNote ? (60 + (a[\rate] ? 1).ratiomidi) } };
            dur = switch(def,
                \tenori, { 0.18 },
                \es335, { 1.8 },
                \obx, { (a[\att] ? 0.4) + (a[\dur] ? 2) },
                \prophet, { (a[\att] ? 0.1) + (a[\dur] ? 1.5) },
                \therevox, { 0.08 + (a[\dur] ? 1.5) + 0.3 },
                \samp1, { min(a[\rel] ? 10, ~vizBufDur.(a[\buf]) / (a[\rate] ? 1).abs).clip(0.05, 4) },
                \samp2, { min(a[\rel] ? 10, ~vizBufDur.(a[\buf]) / (a[\rate] ? 1).abs).clip(0.05, 4) },
                \crush1, { (a[\len] ? 0.06) * (a[\reps] ? 4) },
                \crush2, { (a[\len] ? 0.06) * (a[\reps] ? 4) },
                { a[\decay] ? 0.4 }
            );
            vel = (((a[\amp] ? 0.2) / (~vizRef[def] ? 0.2)).clip(0.25, 1.2) * 100).asInteger.clip(1, 127);
            ty = (~curType ? \other).asString;
            mac = (~curMac ? "unknown").asString;
            inst = if([\samp1, \samp2].includes(def)) { (~vizBank ? "sample").asString } {
                if([\crush1, \crush2].includes(def)) { "glitch" } { def.asString } };
            // Sent straight away, with how long until the sound starts, so the page can fly
            // the traffic in to land at exactly the moment you hear the note.
            ~vizAddr.sendMsg("/viz", ty, note.asFloat, vel, dur.clip(0.05, 8).asFloat, mac,
                             (s.latency + offset).asFloat, inst, (~curGesture ? "?").asString,
                             (~curSize ? 0).asInteger, (~trig ? 0).asInteger);
        };
    };

    ~play = { |def, args, offset = 0|
        try { ~vizSend.(def, args, offset) };   // the visuals must never be able to stop the music
        s.makeBundle(s.latency + offset, { Synth(def, args, ~srcGroup) });
    };

    ~playSamp = { |buf, amp = 0.3, pan = 0, offset = 0, rate = 1, rel = 10, rev = 0.1, echo = 0, back = 0|
        var def = if(buf.numChannels == 2) { \samp2 } { \samp1 };
        ~play.(def, [\buf, buf, \rate, rate, \amp, amp, \pan, pan, \rel, rel,
                     \rev, rev, \echo, echo, \back, back], offset);
    };

    ~playNote = { |map, note, amp, pan, offset, rel = 4, rev = 0.3, echo = 0.3|
        var best;
        if(map.notEmpty) {
            best = map[0];
            map.do { |e| if((e[0] - note).abs < (best[0] - note).abs) { best = e } };
            ~vizNote = note;
            ~vizBank = if(map === ~harp) { "harp" } { if(map === ~rhodes) { "rhodes" } { "sample" } };
            ~playSamp.(best[1], amp, pan, offset, (note - best[0]).midiratio, rel, rev, echo);
            ~vizNote = nil; ~vizBank = nil;
        };
    };

    ~voice = { |inst, note, amp, pan, t, bright = 0.5|
        if(0.1.coin and: { [\buchla, \tenori, \microfreak, \arp2600].includes(inst) }) {
            note = note + [-0.7, -0.5, -0.33, -0.25, 0.25, 0.33, 0.5, 0.7, 11.5, -11.5].choose;     // Terra-style microtonal wrongness
        };
        if([\sub37, \jazzbass].includes(inst)) { while { note > 55 } { note = note - 12 } };  // basses live low
        switch(inst,
            \buchla, { ~play.(\buchla, [\freq, note.midicps, \amp, amp * 0.22, \pan, pan,
                           \ratio, [1, 1.5, 2, 2.5, 3.01].choose, \index, rrand(0.5, 3) * (0.5 + bright),
                           \fold, rrand(0.5, 4), \decay, rrand(0.15, 0.8), \rev, 0.25, \echo, 0.35], t) },
            \arp2600, { ~play.(\arp2600, [\freq, note.midicps, \amp, amp * 0.2, \pan, pan,
                           \ring, [0.5, 1.5, 2.01, 3.5].choose, \res, rrand(0.08, 0.3),
                           \decay, rrand(0.1, 0.4), \noise, [0, 0, 0.3].choose, \rev, 0.2, \echo, 0.3], t) },
            \cs, { ~play.(\cs, [\freq, note.midicps, \amp, amp * 0.2, \pan, pan, \decay, rrand(0.3, 1.2),
                           \cut, 1.5 + (bright * 4), \rev, 0.3, \echo, 0.3], t) },
            \tenori, { ~play.(\tenori, [\freq, note.midicps, \amp, amp * 0.15, \pan, pan, \rev, 0.3, \echo, 0.4], t) },
            \sub37, { ~play.(\sub37, [\freq, note.midicps, \amp, amp * 0.35, \pan, pan * 0.3,
                           \decay, rrand(0.2, 0.9), \cut, 2 + (bright * 6), \drive, rrand(1.5, 3), \rev, 0.05, \echo, 0.1], t) },
            \jazzbass, { ~play.(\jazzbass, [\freq, note.midicps, \amp, amp * 0.45, \pan, pan * 0.3,
                           \decay, rrand(0.6, 2), \rev, 0.1, \echo, 0.05], t) },
            \microfreak, { ~play.(\microfreak, [\freq, note.midicps, \amp, amp * 0.3, \pan, pan,
                           \mode, [0, 1, 2].choose, \decay, rrand(0.1, 0.5), \rev, 0.2, \echo, 0.4], t) },
            \es335, { ~play.(\es335, [\freq, note.midicps, \amp, amp * 0.35, \pan, pan, \rev, 0.3, \echo, 0.25], t) },
            \rhodes, { ~playNote.(~rhodes, note, amp * 0.45, pan, t, 3, 0.3, 0.3) },
            \harp, { ~playNote.(~harp, note, amp * 0.55, pan, t, 4, 0.35, 0.3) }
        );
    };

    // ----------------------------------------------------- packet -> music
    ~gestureNames = [\note, \call, \run, \chord, \glide, \sh, \glitch, \perc, \bass];
    ~gestureWeights = (                       // packet type nudges the odds, chance decides
        mdns:  [5, 2, 1, 1, 1, 1, 1, 1, 1],
        dns:   [2, 5, 1, 1, 1, 1, 1, 1, 1],
        arp:   [1, 1, 5, 1, 1, 2, 1, 1, 2],
        ssdp:  [1, 1, 1, 5, 2, 1, 1, 1, 2],
        udp:   [3, 1, 1, 1, 1, 3, 1, 2, 2],
        https: [2, 1, 1, 1, 1, 1, 2, 4, 2],
        tcp:   [1, 1, 1, 1, 1, 1, 3, 4, 2]
    );

    ~big = { |sw|                             // a device joining the network
        var pool;
        ~drift.("new device joined");
        pool = ~pool.(55, 79);
        ~play.([\obx, \prophet].choose, [\notes, [0, 2, 4, 6].collect { |k| pool.clipAt(k) }, \amp, 0.12,
                      \att, 1.5, \dur, 4, \rev, 0.5, \echo, 0.2], sw);
        ~voice.([\sub37, \jazzbass].choose, pool[0], 0.8, 0, sw, 0.5);
        ~pool.(60, 88).do { |n, k| ~voice.(\harp, n, 0.5, -0.6 + (k * 0.08), sw + 0.8 + (k * 0.05)) };
    };

    ~event = { |type, size, mac, energy, sw|
        var frac, amp, pan, g, w, inst, reg, pool, i, notes, n2, len, dir, buf;
        type = type.asSymbol;
        ~curType = type; ~curMac = mac;                          // for the visualiser
        ~curSize = size; ~curGesture = if(type == \dhcp) { "join" } { "?" }; ~trig = (~trig ? 0) + 1;
        frac = (size.clip(42, 1514).log - 42.log) / (1514.log - 42.log);
        amp = 0.5 + (0.5 * frac);
        pan = rrand(-0.8, 0.8);
        reg = [[48, 67], [55, 74], [62, 81], [67, 88]].wchoose([0.12, 0.33, 0.35, 0.2]);
        pool = ~pool.(reg[0], reg[1]);
        i = (frac * pool.size).asInteger.clip(0, pool.size - 1);

        if(type == \dhcp) { ~big.(sw) } {
            w = (~gestureWeights[type] ? [2, 1, 1, 1, 1, 1, 1, 1, 1]).copy;
            w[3] = w[3] * 1.5; w[6] = w[6] * 2 * (0.3 + (energy * 2));                     // more glitches when busy
            g = ~gestureNames.wchoose(w.normalizeSum);
            ~curGesture = g.asString;

            switch(g,
                \note, {
                    inst = [\buchla, \cs, \tenori, \arp2600, \rhodes, \harp, \microfreak, \es335]
                           .wchoose([3, 2, 2, 1, 2, 2, 2, 2].normalizeSum);
                    ~voice.(inst, pool[i], amp, pan, sw, frac);
                },
                \call, {                                          // question and answer across the room
                    inst = [\buchla, \cs, \rhodes, \harp, \tenori, \microfreak, \es335].choose;
                    ~voice.(inst, pool[i], amp, pan, sw, frac);
                    ~voice.(inst, pool.clipAt(i + [2, 3, -2].choose), amp * 0.8, pan.neg,
                            sw + (~stepDur * [1, 2, 3].choose), frac);
                },
                \run, {                                           // Tenori-On / Buchla arpeggio
                    inst = [\tenori, \buchla, \harp, \cs, \microfreak].choose;
                    len = rrand(3, 8);
                    dir = [1, -1].choose;
                    n2 = [0.5, 1].choose;
                    len.do { |k|
                        ~voice.(inst, pool.clipAt(i + (k * dir)), amp * 0.8, (pan + (k * 0.1 * dir)).clip(-1, 1),
                                sw + (k * ~stepDur * n2), frac);
                    };
                },
                \chord, {
                    notes = [0, 2, 4, 6].collect { |k| pool.clipAt(i + k) };
                    switch([\obx, \prophet, \rhodes, \harp, \es335].wchoose([0.2, 0.25, 0.2, 0.2, 0.15]),
                        \obx, { ~play.(\obx, [\notes, notes, \amp, 0.1 * amp, \pan, pan * 0.5,
                                              \att, rrand(0.05, 0.8), \dur, rrand(0.8, 3), \rev, 0.4, \echo, 0.2], sw) },
                        \prophet, { ~play.(\prophet, [\notes, notes, \amp, 0.1 * amp, \pan, pan * 0.5,
                                              \att, rrand(0.02, 0.6), \dur, rrand(0.6, 2.5), \cut, rrand(1200, 4000),
                                              \rev, 0.35, \echo, 0.25], sw) },
                        \es335, { notes.do { |nn, k| ~voice.(\es335, nn - 12, amp * 0.8, pan + (k * 0.08), sw + (k * 0.025)) } },
                        \rhodes, { notes.do { |nn, k| ~voice.(\rhodes, nn, amp * 0.8, pan + (k * 0.1), sw + (k * 0.03)) } },
                        \harp, { notes.do { |nn, k| ~voice.(\harp, nn, amp * 0.8, pan + (k * 0.1), sw + (k * 0.06)) } }
                    );
                },
                \glide, {                                         // Therevox swoop
                    ~play.(\therevox, [\freq, pool[i].midicps, \freq2, pool.clipAt(i + [-3, -2, 2, 3, 4].choose).midicps,
                                       \glide, rrand(0.2, 1.2), \dur, rrand(0.6, 2), \amp, 0.15 * amp, \pan, pan,
                                       \rev, 0.4, \echo, 0.35], sw);
                },
                \sh, {                                            // ARP 2600 sample-and-hold run
                    len = rrand(4, 10);
                    inst = [\arp2600, \microfreak].choose;
                    len.do { |k| ~voice.(inst, pool.choose, amp * 0.7, pan, sw + (k * ~stepDur / 2), frac) };
                },
                \glitch, {
                    if(~glitchSrc.notEmpty) {
                        buf = ~glitchSrc.choose;
                        ~play.(if(buf.numChannels == 2) { \crush2 } { \crush1 },
                               [\buf, buf, \rate, [0.5, 1, 1, 2].choose, \start, rrand(0, 0.6),
                                \len, rrand(0.02, 0.12), \reps, rrand(2, 8), \srate, [4000, 8000, 11025, 22050].choose,
                                \bits, [4, 6, 8, 12].choose, \amp, 0.25 * amp, \pan, pan, \rev, 0.2, \echo, 0.4], sw);
                    };
                },
                \bass, {                                          // Sub 37 or Jazz Bass, sometimes a two-note figure
                    inst = [\sub37, \jazzbass].choose;
                    ~voice.(inst, pool[i], amp, pan, sw, frac);
                    if(0.4.coin) { ~voice.(inst, pool.clipAt(i + [1, 2, -1].choose), amp * 0.8, pan,
                                           sw + (~stepDur * [2, 3].choose), frac) };
                },
                \perc, {                                          // chopped, pitched, sometimes reversed
                    if(~perc.notEmpty) {
                        ~vizBank = "perc";
                        ~playSamp.(~perc.choose, amp * 0.35, pan, sw, [0.5, 0.75, 1, 1, 1, 1.5, 2].choose,
                                   2, 0.2, [0, 0, 0.4].choose, if(0.2.coin) { 1 } { 0 });
                        ~vizBank = nil;
                    };
                }
            );
            if(~verbose) { (type.asString ++ " " ++ size ++ " -> " ++ g ++ (inst !? { " on " ++ inst } ? "")).postln };
        };
    };

    // ------------------------------------------------ bluetooth sparkles
    // Signal strength = distance: near is loud, bright and dry; far is quiet and washed in reverb.
    ~bleEvent = { |kind, rssi, sw, id|
        var near = rssi.linlin(-100, -40, 0, 1), amp = 0.12 + (0.3 * near), rev = 0.75 - (0.55 * near);
        var note = ~pool.(72, 91).choose, pan = rrand(-1.0, 1.0), inst;
        ~curType = "bt"; ~curMac = "bt:" ++ (id ? kind).asString;   // for the visualiser
        ~curSize = rssi; ~curGesture = "sparkle"; ~trig = (~trig ? 0) + 1;
        inst = switch(kind.asSymbol,
            \apple,     { [\harp, \tenori].choose },
            \samsung,   { [\microfreak, \tenori].choose },
            \microsoft, { [\buchla, \microfreak].choose },
            \google,    { [\cs, \harp].choose },
            { [\tenori, \buchla, \harp, \microfreak].choose });
        switch(inst,
            \harp,       { ~playNote.(~harp, note.min(84), amp, pan, sw, 4, rev, 0.4) },
            \tenori,     { ~play.(\tenori, [\freq, note.midicps, \amp, amp * 0.5, \pan, pan, \rev, rev, \echo, 0.45], sw) },
            \buchla,     { ~play.(\buchla, [\freq, note.midicps, \amp, amp * 0.5, \pan, pan, \ratio, [2, 3.01, 4].choose,
                                             \index, 1 + near, \fold, 1 + (near * 2), \decay, 0.15 + (0.4 * (1 - near)),
                                             \rev, rev, \echo, 0.45], sw) },
            \microfreak, { ~play.(\microfreak, [\freq, note.midicps, \amp, amp * 0.6, \pan, pan, \mode, [0, 1, 2].choose,
                                                 \decay, rrand(0.08, 0.3), \rev, rev, \echo, 0.45], sw) },
            \cs,         { ~play.(\cs, [\freq, note.midicps, \amp, amp * 0.5, \pan, pan, \decay, 0.5, \cut, 2 + (near * 3),
                                         \rev, rev, \echo, 0.4], sw) }
        );
        if(~verbose) { ("bluetooth " ++ kind ++ " " ++ rssi ++ "dBm -> " ++ inst).postln };
    };

    // ------------------------------------------------------ packet input
    ~queue = [];
    ~packetCount = 0;
    ~rate = 0;
    OSCdef(\packet, { |msg|
        if(~queue.size < 16) { ~queue = ~queue.add([msg[1], msg[2], msg[3]]) };
        ~packetCount = ~packetCount + 1;
    }, '/packet');
    ~bleQueue = [];
    OSCdef(\ble, { |msg|
        if(~bleQueue.size < 8) { ~bleQueue = ~bleQueue.add([msg[1], msg[2], msg[3]]) };
    }, '/ble');

    // --------------------------------------------------------------- clock
    // No backing track - the clock only quantises packets to a swung 16th grid.
    ~step = 0;
    ~decay = (~stepDur.neg / 2).exp;
    ~clock = TempoClock(~bpm / 60);
    ~seq = Routine({
        loop {
            var energy, sw, n, batch, bp;
            ~rate = (~rate * ~decay) + ((~packetCount / ~stepDur) * (1 - ~decay));
            ~packetCount = 0;
            energy = 1 - (~rate.neg / ~busy).exp;
            sw = if(~step.odd) { ~stepDur * ~swing } { 0 };

            if(~step > 0 and: { ~step % 128 == 0 }) { ~drift.("time passes") };

            n = ~queue.size.min(1 + (energy * 2).round.asInteger);
            batch = ~queue.copyRange(0, n - 1);
            ~queue = ~queue.copyToEnd(n);
            batch.do { |p| ~event.(p[0], p[1], p[2], energy, sw) };

            // bluetooth: at most one sparkle per 16th, and not every 16th
            if(~bleQueue.notEmpty and: { 0.5.coin }) {
                bp = ~bleQueue[0];
                ~bleQueue = ~bleQueue.copyToEnd(1);
                ~bleEvent.(bp[0], bp[1], sw, bp[2]);
            };

            ~step = ~step + 1;
            0.25.wait;
        }
    });
    ~seq.play(~clock, quant: 1);

    ("netsong ready in " ++ ~keys[~keyIdx][0] ++ " at " ++ ~bpm ++ " BPM - " ++
     ~rhodes.size ++ " Rhodes, " ++ ~harp.size ++ " harp, " ++ ~perc.size ++ " percussion samples").postln;
};
)
