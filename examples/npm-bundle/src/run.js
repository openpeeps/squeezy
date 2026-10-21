import MainDef from 'pkg-main';
import * as MainNs from 'pkg-main';
import { alpha } from 'pkg-main';
import { beta } from '@scope/pkg-module';
import { gamma } from 'pkg-exports';
import { delta } from 'pkg-exports/feature';
import { help } from './helper.js';

console.log([alpha, beta, gamma, delta, MainDef(), MainNs.alpha, help(null)].join('|'));
