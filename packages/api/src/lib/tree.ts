import { buildMerkleTree, saveTree, IMerkleTree, loadTree } from "adb";
import { IDatabaseMetadata } from "./media-file-database";
import { IStorage } from "storage";

//
// Saves the merkle tree to disk.
//
export async function saveMerkleTree(merkleTree: IMerkleTree<IDatabaseMetadata>, metadataStorage: IStorage): Promise<void> {
    if (!merkleTree) {
        throw new Error("Cannot save database. No merkle tree provided.");
    }

    if (merkleTree.dirty) {
        merkleTree.merkle = buildMerkleTree(merkleTree.sort);
        merkleTree.dirty = false;
    }

    await saveTree("tree.dat", merkleTree, metadataStorage);
}

//
// Loads the merkle tree from disk.
//
export async function loadMerkleTree(metadataStorage: IStorage): Promise<IMerkleTree<IDatabaseMetadata> | undefined> {
    return await loadTree("tree.dat", metadataStorage);
}
