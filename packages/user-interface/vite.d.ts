interface ImportMeta {
    readonly env: any;
}

declare module '*.css' {
    const content: string;
    export default content;
}