/*

This file is part of the karpsichord project
  at https://github.com/spaskalev/karpsichord

Copyright (C) 2022 Stanislav Paskalev <spaskalev@protonmail.com>

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.

*/

declare options "[midi:on][nvoices:32]";

import("basics.lib");
import("filters.lib");
import("delays.lib");
import("maths.lib");
import("noises.lib");
import("envelopes.lib");
import("stdfaust.lib");
import("compressors.lib");
import("reverbs.lib");

// These UI elements are automatically set by Faust when using MIDI
midi_gate = button("gate");
input_midi_freq = hslider("freq",440,8,22000,1);
tempered_midi_freq = input_midi_freq * cent2ratio(temperament);
midi_gain = hslider("gain",0.5,0,1,0.01);

// The value of the current MIDI note, normalized to [0,1]
max_midi_freq = ba.midikey2hz(127);
min_midi_freq = ba.midikey2hz(0);

// Convert a difference in cents https://en.wikipedia.org/wiki/Cent_(music) to multiplication ratio
cent2ratio(cent) = pow(2.0, cent/1200);

/* Tuning from http://www-personal.umich.edu/~bpl/larips/
Enter the offsets from C, not A. The numbers to use are:
C (0.0), C# (-2.0), D (-3.9), Eb (-2.0), E (-7.8), F (2.0), F# (-3.9), G (-2.0), G# (-2.0), A (-5.9), Bb (-2.0), B (-5.9).
*/
temperament = rdtable(waveform{
    0, -2.0, -3.9, -2.0, -7.8, 2.0, -3.9, -2.0, -2.0, -5.9, -2.0, -5.9
    }, int(ba.hz2midikey(input_midi_freq) % 12));

normalized_midi_freq = ((tempered_midi_freq) - min_midi_freq) / (max_midi_freq - min_midi_freq);

// Excitation noise source is white noise filtered by a two-element convolution filter
noise_period = 48000;
noise_source = rdtable(noise_period, (noise : fir((.5, .5)), ba.sweep(noise_period, midi_gate))) : * (attenuation)
with {
    attenuation = (normalized_midi_freq * m) + c;
    m = 1.15;
    c = 0.45;
};

noise_envelope(signal) = en.ar(attack, release, signal)
with {
    total_length = (normalized_midi_freq * m) + c;
    ratio = 0.65;
    m = -0.185;
    c = 0.03;
    attack = total_length * ratio;
    release = total_length * (1 - ratio);
};

// Generate excitation on trigger signal using a fire-and-forget envelope
initial_samples(signal) = (noise_source * noise_envelope(signal));

// A line equation that modifies the sample delay and therefore the notes' pitch
tuning_gradient = (0.55 * normalized_midi_freq) - 1.2;

// The sample delay length. Based on the current sampling rate, note and compensation.
loop_delay = (ma.SR / tempered_midi_freq) + tuning_gradient;

// Sample delay via fifth-order Lagrange interpolation. Might be an overkill.
sample_delay(signal) = fdelay5(4096, loop_delay, signal);

// A stretched convolution filter that extends high notes' duration
string_filter(i) = (c*i) + (d * (i'))
with {
    d = S * 0.5;
    c = 1 - d;
    S = normalized_midi_freq : * (2.35) : + (-0.625) : exp : * (-0.1) : + (0.35);
};

// A log-based attenuation that shortens low notes' duration
string_decay(i) = (i*k)
with {
    k = min(0.999, 1 - ( normalized_midi_freq : * (20) : + (0.05) : log : * (-0.005) : + (0)));
};

// Pick position comb filter based on the loop delay for the current note.
pick_position(position, s) = delay(4096, position * loop_delay, s) : - (s);

process = midi_gate <: ((initial_samples : pick_position(0.15) : (+ (_) : sample_delay  : string_filter : string_decay) ~ _)/2 +
                        (initial_samples : pick_position(0.10) : (+ (_) : sample_delay  : string_filter : string_decay) ~ _)/2)
          * (en.are(0.20 + (0.05 * (1 - midi_gain)), 1)) <: _, _;

n = 6;
stereo = delay(128, n/2), delay(128, ba.sweep(n+1, 0));

effect = stereo : limiter_lad_N(2, .01, 0.99, .01, .1, 1)
        : low_shelf(4.5, 215)
        : peak_eq(-2.0, 550, 375)
        : high_shelf(1.5, 600)
        : dm.zita_rev_fdn(
            110, // f1: crossover frequency (Hz) separating dc and midrange frequencies
            440, // f2: frequency (Hz) above f1 where T60 = t60m/2 (see below)
            1.85, // t60dc: desired decay time (t60) at frequency 0 (sec)
            3.15, // t60m: desired decay time (t60) at midrange frequencies (sec)
            48000); // max sampling rate
