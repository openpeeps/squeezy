import { alpha } from 'pkg-main';
import MainDef from 'pkg-main';
import * as MainNs from 'pkg-main';
import { beta } from '@scope/pkg-module';
import { gamma } from 'pkg-exports';
import { delta } from 'pkg-exports/feature';
import { epsilon, help } from './helper.js';

const zeta = require('pkg-main');

export { beta } from '@scope/pkg-module';

const nothingHere = null;
const notDefined = undefined;

console.log(alpha, beta, gamma, delta, epsilon, zeta, help(nothingHere), notDefined);
console.log(MainDef, MainNs);
