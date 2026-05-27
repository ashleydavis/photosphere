import React, { useEffect } from "react";
import { ToastContainer } from "../../components/toast-container";
import { MockProviders } from "../mocks";
import { useToast } from "../../context/toast-context";
import type { IStory } from "../types";

//
// Seeds the toast context with one toast per color so the container has
// something to render.
//
function SeedToasts() {
    const { addToast } = useToast();
    useEffect(() => {
        addToast({ message: "Operation succeeded", color: "success" });
        addToast({ message: "Something failed", color: "danger" });
        addToast({ message: "Just so you know", color: "primary" });
    }, [addToast]);
    return null;
}

//
// Stories for the ToastContainer.
//
export const stories: IStory[] = [
    {
        id: "toast-container/empty",
        name: "Toast Container (empty)",
        category: "Components",
        render: () => (
            <MockProviders>
                <ToastContainer />
            </MockProviders>
        ),
    },
    {
        id: "toast-container/with-toasts",
        name: "Toast Container (with toasts)",
        category: "Components",
        render: () => (
            <MockProviders>
                <SeedToasts />
                <ToastContainer />
            </MockProviders>
        ),
    },
];
