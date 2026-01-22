import React, { ReactNode, createContext, useContext, useState } from "react";
import { useGallery } from "./gallery-context";
import { useAssetDatabase } from "./asset-database-source";
import { DeleteConfirmationDialog } from "../components/delete-confirmation-dialog";

export interface IDeleteConfirmationContext {
    //
    // Set to true to open the delete confirmation dialog.
    //
    setDeleteConfirmationOpen: (open: boolean) => void;
}

const DeleteConfirmationContext = createContext<IDeleteConfirmationContext | undefined>(undefined);

export interface IDeleteConfirmationContextProviderProps {
    children: ReactNode | ReactNode[];
}

export function DeleteConfirmationContextProvider({ children }: IDeleteConfirmationContextProviderProps) {
    //
    // Set to true to open the delete confirmation dialog.
    //
    const [deleteConfirmationOpen, setDeleteConfirmationOpen] = useState<boolean>(false);

    const { selectedItems, clearMultiSelection } = useGallery();
    const { deleteAssets } = useAssetDatabase();

    const value: IDeleteConfirmationContext = {
        setDeleteConfirmationOpen,
    };
    
    return (
        <DeleteConfirmationContext.Provider value={value}>
            
            {children}
            
            <DeleteConfirmationDialog
                open={deleteConfirmationOpen}
                numItems={selectedItems.size}
                onCancel={() => setDeleteConfirmationOpen(false)}
                onDelete={async () => {
                    await deleteAssets(Array.from(selectedItems.values()));
                    clearMultiSelection();
                    setDeleteConfirmationOpen(false);
                }}
            />
        </DeleteConfirmationContext.Provider>
    );
}

//
// Get the delete confirmation context.
//
export function useDeleteConfirmation() {
    const context = useContext(DeleteConfirmationContext);
    if (!context) {
        throw new Error(`DeleteConfirmationContext is not set! Add DeleteConfirmationContextProvider to the component tree.`);
    }
    return context;
}

