export const toIconPath = (svg: string) => svg.match(/ d="([^"]+)"/)?.[1] ?? '';
