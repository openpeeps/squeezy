export const epsilon = 'rel';

export function help(x) {
  if (x === null || x === undefined) {
    return epsilon;
  }
  return x;
}

export function totalize(firstCount, secondCount) {
  const combinedTotal = firstCount + secondCount;
  return combinedTotal;
}
