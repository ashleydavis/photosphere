import * as crypto from 'crypto';
import * as path from 'path';
import { IStorage, pathJoin } from 'storage';
import { uuid } from 'utils';

//
// Represents a directory.
//
export interface IDirectory {
    name: string;
    directory?: IDirectory;
}

/**
 * Interface for a node in the Merkle tree
 */
export interface MerkleNode {
    hash: Buffer; // The hash for this node.
    fileName?: string; // The file this hash represents, for leaf nodes only.
    directory?: IDirectory; // The directory that contains the file.
    leftNode?: MerkleNode; // Left child node.
    rightNode?: MerkleNode; // Right child node.
}

/**
 * Interface for file hash information
 */
export interface FileHash {
    fileName: string; // The file this hash represents. This is relative to the asset database directory.
    directory?: IDirectory; // The directory that contains the file.
    hash: Buffer; // The hash for this file.
    length: number; // The size of the file in bytes.
}

export function fullDir(directory: IDirectory): string {
    if (directory.directory) {
        return fullDir(directory.directory) + `/` + directory.name;
    }
    else {
        return directory.name;
    }
}

export function fullPath(fileName: string, directory?: IDirectory): string {
    if (directory) {
        return pathJoin(fullDir(directory), fileName);
    }
    else {
        return fileName;
    }
}

export function _fullPath(fileHash: FileHash): string {
    if (fileHash.directory) {
        return pathJoin(fullDir(fileHash.directory), fileHash.fileName);
    }
    else {
        return fileHash.fileName;
    }
}

/**
 * Interface for tree metadata
 */
export interface TreeMetadata {
    id: string;                  // Unique identifier for this database
    totalNodes: number;          // Total number of nodes in the tree
    totalFiles: number;          // Total number of leaf nodes (files)
    totalFileSize: number;       // Total size of all files in bytes
    createdDate: string;         // ISO date string when tree was first created
    lastUpdatedDate: string;     // ISO date string when tree was last updated
}

/**
 * Class representing a Merkle tree that loads nodes incrementally
 */
export class MerkleTree {
    private rootNode: MerkleNode | undefined = undefined;
    private metadata: TreeMetadata;

    private readonly metadataFilePath = 'metadata.json';
    private readonly treeFilePath = 'tree.dat';

    /**
     * Gets the tree metadata
     */
    getMetadata(): TreeMetadata {
        return { ...this.metadata };
    }

    constructor(private metadataStorage: IStorage) {
        this.metadata = {
            id: uuid(),
            totalNodes: 0,
            totalFiles: 0,
            totalFileSize: 0,
            createdDate: new Date().toISOString(),
            lastUpdatedDate: new Date().toISOString()
        };
    }

    //
    // Creates the merkle tree.
    //
    async create(): Promise<void> {
        await this.save();
    }

    /**
     * Initializes the tree by loading nodes/hashes from files
     */
    async load(): Promise<boolean> {
        await this.loadNodes();
        await this.loadMetadata();
        return !!this.rootNode;
    }

    /**
     * Loads metadata from the metadata file
     */
    private async loadMetadata(): Promise<void> {
        const metadataData = await this.metadataStorage.read(this.metadataFilePath);
        if (metadataData) {
            this.metadata = JSON.parse(metadataData.toString('utf8'));
        }
    }

    /**
     * Loads tree nodes from serialized file using recursive depth-first approach
     */
    private async loadNodes(): Promise<void> {
        const treeData = await this.metadataStorage.read(this.treeFilePath);
        if (!treeData) {
            return;
        }

        // Recursive function to read nodes
        const readNode = (offset: number): { node: MerkleNode, offset: number } => {
            // Read hash
            const hash = treeData.slice(offset, offset + 32);
            offset += 32;

            // Read file path.
            const filePathLength = treeData.readUInt16LE(offset);
            offset += 2;

            let filePath: string | undefined;
            if (filePathLength > 0) {
                filePath = treeData.slice(offset, offset + filePathLength).toString('utf8');
                offset += filePathLength;
            }

            let leftNode: MerkleNode | undefined;
            let rightNode: MerkleNode | undefined;

            // If this is not a leaf node (hashIndex == 0), read its children
            if (filePathLength === 0) {
                // Read left child node
                const { node: left, offset: offsetAfterLeft } = readNode(offset);
                leftNode = left;
                offset = offsetAfterLeft;

                // Read right child node
                const { node: right, offset: offsetAfterRight } = readNode(offset);
                offset = offsetAfterRight;
                rightNode = right;
            }

            // Create node
            const node: MerkleNode = {
                hash,
                fileName: filePath && path.basename(filePath),
                directory: filePath && { name: path.dirname(filePath) } || undefined,
                leftNode,
                rightNode
            };

            return {
                node,
                offset,
            };
        };

        // Start reading nodes from the beginning (root node first)
        const { node, offset } = readNode(0);

        // The first node we read is the root node
        this.rootNode = node;
    }

    /**
     * Serializes and saves tree nodes to file using recursive depth-first traversal
     */
    private async saveNodes(): Promise<void> {
        if (!this.rootNode) {
            return;
        }

        const chunks: Buffer[] = [];
        let totalSize = 0;

        function serializeNode(node: MerkleNode): void {

            if (node.hash.length !== 32) {
                throw new Error(`Invalid hash length: ${node.hash.length}`);
            }

            const fullFilePath = node.fileName && fullPath(node.fileName, node.directory);
            const filePathLength = fullFilePath ? Buffer.byteLength(fullFilePath, 'utf8') : 0;

            const nodeBufferSize = node.hash.length + 2 + filePathLength;

            // Create node buffer with fixed size:
            // - 32 bytes for hash
            // - 4 bytes for index (0 = internal node, >0 = leaf node with index-1)
            const nodeBuffer = Buffer.alloc(nodeBufferSize);

            let offset = 0;

            // Write hash
            node.hash.copy(nodeBuffer, offset);
            offset += 32;

            //
            // Write file path if present.
            //
            //TODO: Reuse directories to make the output format more efficient.
            //
            nodeBuffer.writeUInt16LE(filePathLength, offset);
            offset += 2;

            if (fullFilePath) {
                // Write file path
                nodeBuffer.write(fullFilePath, offset, 'utf8');
                offset += filePathLength;
            }

            // Add node to chunks
            chunks.push(nodeBuffer);
            totalSize += nodeBuffer.length;

            if (!node.fileName) {
                // Not a leaf node (no filePath)
                // Recursively serialize children if present
                if (!node.leftNode) {
                    throw new Error('Left node missing');
                }
                if (!node.rightNode) {
                    throw new Error('Right node missing');
                }
                serializeNode(node.leftNode);
                serializeNode(node.rightNode);
            }
        };

        // Start serialization from root
        serializeNode(this.rootNode!);

        // Create a final buffer with all nodes and save it.
        const finalBuffer = Buffer.concat(chunks, totalSize);
        await this.metadataStorage.write(this.treeFilePath, undefined, finalBuffer);
    }

    /**
     * Saves the tree metadata to storage
     */
    private async saveMetadata(): Promise<void> {
        this.metadata.lastUpdatedDate = new Date().toISOString();
        await this.metadataStorage.write(
            this.metadataFilePath,
            undefined,
            Buffer.from(JSON.stringify(this.metadata, null, 2))
        );
    }

    //
    // Gets the root node of the tree.
    //
    getRootNode(): MerkleNode | undefined {
        return this.rootNode;
    }

    /**
     * Gets the root hash of the tree
     */
    getRootHash(): string | undefined {
        if (!this.rootNode) {
            return undefined;
        }
        return this.rootNode.hash.toString('hex');
    }

    /**
     * Saves all tree data
     */
    async save(): Promise<void> {
        if (!this.rootNode) {
            throw new Error('Cannot save tree: no root hash set');
        }

        // Save nodes and hashes
        await this.saveNodes();

        // Save metadata
        await this.saveMetadata();
    }

    // Level-indexed nodes to track incomplete pairs across levels.
    private levelNodes: Map<number, MerkleNode[]> = new Map();

    /**
     * Finds a node for a file in the tree
     * @param fileName - The name of the file to find
     * @param directory - The directory of the file
     * @returns The node if found, undefined otherwise, and its parent node if it has one
     */
    findFileNode(fileName: string, directory?: IDirectory): { node: MerkleNode, parent?: MerkleNode } | undefined {
        if (!this.rootNode) {
            return undefined;
        }

        // Use a stack to traverse the tree without recursion.
        const stack: { node: MerkleNode, parent?: MerkleNode }[] = [{ node: this.rootNode }];
        
        while (stack.length > 0) {
            const { node, parent } = stack.pop()!;
            
            // Check if this is the file node we're looking for.
            if (node.fileName === fileName) {
                // For directory comparison, we need to check the full path.
                const nodePath = fullPath(fileName, node.directory);
                const searchPath = fullPath(fileName, directory);
                
                if (nodePath === searchPath) {
                    return { node, parent };
                }
            }
            
            // Add child nodes to the stack.
            if (node.rightNode) {
                stack.push({ node: node.rightNode, parent: node });
            }

            if (node.leftNode) {
                stack.push({ node: node.leftNode, parent: node });
            }
        }
        
        return undefined;
    }

    /**
     * Finds a path from the root to a specific node.
     * @param targetNode - The node to find a path to
     * @returns Array of nodes representing the path from root to target, or undefined if not found
     */
    private findPathToNode(targetNode: MerkleNode): MerkleNode[] | undefined {
        if (!this.rootNode) {
            return undefined;
        }

        // Use a stack for DFS traversal with the current node and path to it.
        interface StackItem {
            node: MerkleNode;
            path: MerkleNode[];
        }
        
        const stack: StackItem[] = [];
        stack.push({ node: this.rootNode, path: [ this.rootNode ] });
        
        while (stack.length > 0) {
            const { node, path } = stack.pop()!;
            
            if (node === targetNode) {
                return path;
            }
            
            // Check right child first (depth-first).
            if (node.rightNode) {
                const newPath = path.slice();
                newPath.push(node.rightNode);
                stack.push({ node: node.rightNode, path: newPath });
            }
            
            // Then check left child.
            if (node.leftNode) {
                const newPath = path.slice();
                newPath.push(node.leftNode);
                stack.push({ node: node.leftNode, path: newPath });
            }
        }
        
        return undefined;
    }

    /**
     * Updates hashes from a node all the way up to the root
     * @param node - The node whose hash was updated
     * @param parent - The parent of the node
     */
    private updateNodeHashes(parent?: MerkleNode): void {
        if (!this.rootNode || !parent) {
            return;
        }
        
        // First, find the path from root to the parent node.
        // We'll need to update all nodes along this path.
        const pathToParent = this.findPathToNode(parent);
        if (!pathToParent) {
            return;
        }
        
        // We need to process nodes from leaf to root.
        // So we reverse the path (which is from root to leaf).
        const nodesToUpdate = pathToParent.reverse();
        
        // Add the parent to the beginning (if not already there)
        if (nodesToUpdate[0] !== parent) {
            nodesToUpdate.unshift(parent);
        }
        
        // Update the hashes for each node in the path.
        for (const node of nodesToUpdate) {

            if (node.fileName) {
                // Leaf node, this should have the hash of the updated file.
            }
            else {
                // Combine hashes to create parent hash
                node.hash = crypto.createHash('sha256')
                    .update(node.leftNode!.hash)
                    .update(node.rightNode!.hash)
                    .digest();
            }            
        }
    }

    /**
     * Adds a single file hash to the tree and updates the tree structure
     * Only pairs nodes during this stage, unpaired nodes will be processed later
     * @param fileHash - File hash to add to the tree
     */
    addFileHash(fileHash: FileHash): void {
        // Check if the file already exists in the tree.
        const existingNode = this.findFileNode(fileHash.fileName, fileHash.directory);        
        if (existingNode) {
            // Update the existing node's hash
            existingNode.node.hash = fileHash.hash;
            
            // Update all parent hashes up to the root
            this.updateNodeHashes(existingNode.parent);
            
            // Update the lastUpdatedDate in metadata
            this.metadata.lastUpdatedDate = new Date().toISOString();
            
            return;
        }

        // If the file doesn't exist, add it as a new node
        const leafNode: MerkleNode = {
            hash: fileHash.hash,
            fileName: fileHash.fileName,
            directory: fileHash.directory,
        };

        //
        // Add a new leaf node to the bottom level.
        //
        this.processNodeAtLevel(0, leafNode);

        // Select an intermediate root node.
        if (this.levelNodes.size > 0) {
            const topLevel = this.levelNodes.get(this.levelNodes.size - 1);
            if (topLevel && topLevel.length == 1) {
                const [ rootHash ] = topLevel.values();
                this.rootNode = rootHash;
            }
        }

        this.metadata.totalNodes++;
        this.metadata.totalFiles++;
        this.metadata.totalFileSize += fileHash.length;
        this.metadata.lastUpdatedDate = new Date().toISOString();
   }

    /**
     * Process a node at a specific level of the tree.
     */
    private processNodeAtLevel(level: number, node: MerkleNode): void {


        if (!this.levelNodes.has(level)) {
            this.levelNodes.set(level, []); // Ensure we have a map for this level.
        }

        const levelMap = this.levelNodes.get(level)!;

        // Store this node at its index in the current level.
        levelMap.push(node);

        //
        // If we have at least two nodes at this level, we can pair them.
        //
        while (levelMap.length >= 2) {
            // We found a pair! 
            // Remove both nodes from the current level map.
            const [leftNode, rightNode] = levelMap.splice(0, 2); // Remove the first two nodes.

            // Create the parent node of two adjacent nodes.
            const parentLevel = level + 1;
            const parent = this.createParentNode(leftNode, rightNode);
            this.processNodeAtLevel(parentLevel, parent);

            this.metadata.totalNodes++;
        }
    }

    //
    // Creates a parent node from two child nodes.
    //
    private createParentNode(leftNode: MerkleNode, rightNode: MerkleNode): MerkleNode {

        // Combine hashes to create parent.
        const parentHashGenerator = crypto.createHash('sha256')
            .update(leftNode.hash)
            .update(rightNode.hash);
        const parentHash = parentHashGenerator.digest();

        // Create parent node
        const parent: MerkleNode = {
            hash: parentHash,
            leftNode,
            rightNode,
        };

        return parent;
    }

    /**
     * Completes the tree by processing all unpaired nodes
     * Call this after all file hashes have been added to the tree
     */
    complete(): void {
        for (let level = 0; level < this.levelNodes.size; level++) {
            const levelMap = this.levelNodes.get(level);
            if (!levelMap || levelMap.length === 0) {
                // No nodes at this level
                continue;
            }

            if (levelMap.length === 1) {
                // If we are at the top level, we can exit here instead of creating a new level
                if (level === this.levelNodes.size - 1) {
                    break;
                }

                // We have one node, promote it to the next level.
                const [ node ] = levelMap.splice(0, 1); // Remove the first node.

                //
                // Allocate the next level, if not already existing.
                //
                const parentLevel = level + 1;
                let parentLevelMap = this.levelNodes.get(parentLevel);
                if (!parentLevelMap) {
                    parentLevelMap = [];
                    this.levelNodes.set(parentLevel, parentLevelMap);
                }

                //
                // Add the parent node to the next level.
                //
                parentLevelMap.push(node);
            }
            else if (levelMap.length === 2) {                
                // We have two nodes here, must be because one was promoted from the previous level.
                const [leftNode, rightNode]  = levelMap.splice(0, 2); // Remove the first two nodes.

                const parent = this.createParentNode(leftNode, rightNode);

                // Add the parent to the next level up.
                const parentLevel = level + 1;
                let parentLevelMap = this.levelNodes.get(parentLevel);
                if (!parentLevelMap) {
                    parentLevelMap = [];
                    this.levelNodes.set(parentLevel, parentLevelMap);
                }

                parentLevelMap.push(parent);

                this.metadata.totalNodes++;
            }
            else {
                // We have an odd number of nodes at this level, which is unexpected.
                throw new Error(`Unexpected number of nodes at level ${level}: ${levelMap.length}`);
            }
        }

        // If everything went well, we only have one node remaining at the top level.
        if (this.levelNodes.size === 0) {
            throw new Error(`Unexpected number of levels: ${this.levelNodes.size}`);
        }

        const topLevel = this.levelNodes.get(this.levelNodes.size - 1);
        if (!topLevel) {
            throw new Error(`No nodes at the top level: ${this.levelNodes.size-1}`);
        }

        if (topLevel.length !== 1) {
            throw new Error(`Unexpected number of nodes ${topLevel.length} at top level ${this.levelNodes.size-1}`);
        }

        const [ rootNode ] = topLevel.values();
        this.rootNode = rootNode;
    }

    /**
     * Visualizes the tree incrementally
     * @param options - Visualization options
     * @returns A string representation of the tree
     */
    visualize(): string {
        let result = "🌲 Merkle Tree\n";

        // Check if we need to show the tree from the root
        if (this.rootNode) {
            if (this.rootNode) {
                // Show the tree structure starting from the root
                result += this.visualizeNodeIncremental(this.rootNode, "", true, 0);
            } else {
                result += "Failed to load root node";
            }
        } else {
            result += "No root hash set";
        }

        if (this.rootNode) {
            result += `Root hash: ${this.rootNode.hash.toString("hex").substring(0, 16)}...\n`;
        }

        return result;
    }

    /**
     * Recursively visualizes a tree node and its children incrementally
     * @param hashHex - The hash of the node to visualize
     * @param prefix - The string prefix to use for the current line (for indentation)
     * @param isLeft - Whether this node is a left child of its parent
     * @param showHashes - Whether to display the full hash values
     * @param depth - Current depth in the tree
     * @param maxDepth - Maximum depth to visualize (-1 for unlimited)
     * @returns A string representation of the node and its children
     */
    private visualizeNodeIncremental(
        node: MerkleNode,
        prefix: string = "",
        isLeft: boolean = true,
        depth: number = 0
    ): string {
        // Prepare the hash representation (shortened or full)
        const nodeHashHex = node.hash.toString('hex');
        const hashStr = `${nodeHashHex.slice(0, 4)}-${nodeHashHex.slice(-4)}`;

        // Create the node representation
        let result = `${prefix}`;

        // Add the connector line
        if (prefix !== "") {
            result += isLeft ? "├── " : "└── ";
        }

        try {
            // If it's a leaf node with a file path
            const filePath = node.fileName && fullPath(node.fileName, node.directory);
            if (filePath) {
                result += `📄 [${hashStr}] ${filePath}\n`;
            }
            else {
                // It's an internal node
                result += `🔗 [${hashStr}]\n`;
            }

            // Calculate new prefix for children
            const childPrefix = prefix + (isLeft ? "│   " : "    ");

            // Recursively visualize children
            if (node.leftNode) {
                result += this.visualizeNodeIncremental(
                    node.leftNode,
                    childPrefix,
                    true,
                    depth + 1
                );
            }

            if (node.rightNode) {
                result += this.visualizeNodeIncremental(
                    node.rightNode,
                    childPrefix,
                    false,
                    depth + 1
                );
            }

            return result;
        }
        catch (error) {
            console.error(`Error parsing node metadata: ${node.hash.toString("hex")}`, error);
            return result + `❌ [${hashStr}] Error: Failed to parse metadata\n`;
        }
    }

}

//
// Traverse the tree and call the callback function for each node.
// If the callback returns false, the traversal stops.
//
export async function traverseTree(tree: MerkleTree, node: MerkleNode, callback: (node: MerkleNode) => Promise<boolean>): Promise<void>  {
    if (!await callback(node)) {
        return;
    }

    if (node.leftNode) {
        await traverseTree(tree, node.leftNode, callback);
    }

    if (node.rightNode) {
        await traverseTree(tree, node.rightNode, callback);
    }
}
