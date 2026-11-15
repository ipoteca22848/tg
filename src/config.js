const config=globalThis.COMPANION_CONFIG||{};
export const URL=config.supabaseUrl;
export const KEY=config.publishableKey;
export const EDGE_JWT=config.edgeJwt;
if(!URL||!KEY||!EDGE_JWT)throw new Error("Не загружен companion-config.js");
