//
// Represents an update to the database.
//
export interface IDatabaseUpdate {
  //
  // The type of the update.
  //
  type: "field" | "delete" | "upsert";

  //
  // The time the update was made.
  //
  timestamp: number;

  //
  // The name of the collection being updated.
  //
  collection: string;

  //
  // The id of the document being updated.
  //
  _id: string;
}

//
// Represents a set field update to the database.
//
export interface IFieldUpdate extends IDatabaseUpdate {
  //
  // The type of the update.
  //
  type: "field";

  //
  // The field being updated.
  //
  field: string;

  //
  // The new value of the field.
  //
  value: any;
}

//
// Represents a delete document update to the database.
//
export interface IDeleteUpdate extends IDatabaseUpdate {
  //
  // The type of the update.
  //
  type: "delete";
}

//
// Represents an upsert document update to the database.
//
export interface IUpsertUpdate extends IDatabaseUpdate {
  //
  // The type of the update.
  //
  type: "upsert";

  //
  // The document data to upsert.
  //
  document: any;
}

//
// The various types of database updates.
//
export type DatabaseUpdate = IFieldUpdate | IDeleteUpdate | IUpsertUpdate;

