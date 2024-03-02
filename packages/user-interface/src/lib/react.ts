
//
// Async version of React's setState.
//
export async function setState<PropsT, StateT>(component: React.Component<PropsT, StateT>, overrides: any): Promise<void> {
    return new Promise<void>((resolve, reject) => {
        component.setState(
            Object.assign({}, component.state, overrides), 
            () => resolve()
        );
    });
}
