// A map held to a fixed size: setting a key moves it to the newest place, and past the limit the
// oldest entry goes. Used for caches keyed by session id, which every /clear adds to.
export const remember = <K, V>(m: Map<K, V>, key: K, value: V, max: number): void => {
  m.delete(key)
  m.set(key, value)
  // A limit below one keeps nothing; never loop on an empty map.
  while (m.size > Math.max(0, max)) m.delete(m.keys().next().value as K)
}
