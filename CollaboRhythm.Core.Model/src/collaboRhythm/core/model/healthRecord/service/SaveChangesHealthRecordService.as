package collaboRhythm.core.model.healthRecord.service
{

	import collaboRhythm.core.model.healthRecord.HealthRecordServiceFacade;
	import collaboRhythm.shared.model.Account;
	import collaboRhythm.shared.model.Record;
	import collaboRhythm.shared.model.healthRecord.DocumentBase;
	import collaboRhythm.shared.model.healthRecord.DocumentCollectionBase;
	import collaboRhythm.shared.model.healthRecord.HealthRecordServiceRequestDetails;
	import collaboRhythm.shared.model.healthRecord.IDocument;
	import collaboRhythm.shared.model.healthRecord.PhaHealthRecordServiceBase;
	import collaboRhythm.shared.model.healthRecord.Relationship;

	import j2as3.collection.HashMap;

	import mx.collections.ArrayCollection;

	import org.indivo.client.IndivoClientEvent;

	/**
	 * Service responsible for persisting changes to documents in a record to a health record server.
	 */
	public class SaveChangesHealthRecordService extends PhaHealthRecordServiceBase
	{
		private var _healthRecordServiceFacade:HealthRecordServiceFacade;
		private var _pendingCreateDocuments:HashMap = new HashMap();
		private var _pendingRemoveDocuments:HashMap = new HashMap();
		private var _relationshipsRequiringDocuments:ArrayCollection = new ArrayCollection();
		private var _pendingRelateDocuments:ArrayCollection = new ArrayCollection();

		public function SaveChangesHealthRecordService(consumerKey:String, consumerSecret:String, baseURL:String, account:Account, healthRecordServiceFacade:HealthRecordServiceFacade)
		{
			super(consumerKey, consumerSecret, baseURL, account);
			_healthRecordServiceFacade = healthRecordServiceFacade;
		}

		/**
		 * Saves all changes to all documents in the specified record to the server.
		 *
		 * @param record The record to save
		 */
		public function saveAllChanges(record:Record):void
		{
			saveChanges(record, record.completeDocumentsById.values(), record.newRelationships);
		}

		/**
		 * Saves changes to all specified documents (documents which must be part of the specified record) to the server.
		 *
		 * @param record The record which the specified documents belong to
		 * @param documents The documents to save
		 * @param relationships The relationships to save
		 */
		public function saveChanges(record:Record, documents:ArrayCollection, relationships:ArrayCollection=null):void
		{
			for each (var document:IDocument in documents)
			{
				if (document.pendingAction == DocumentBase.ACTION_CREATE)
				{
					pendingCreateDocuments.put(document.meta.id, document);
					createDocument(record, document, getDocumentXml(document))
				}
				else if (document.pendingAction == DocumentBase.ACTION_VOID)
				{
					pendingRemoveDocuments.put(document.meta.id, document);
					voidDocument(record, document, document.pendingActionReason);
				}
				else if (document.pendingAction == DocumentBase.ACTION_DELETE)
				{
					pendingRemoveDocuments.put(document.meta.id, document);
					deleteDocument(record, document);
				}
				// TODO: handle other actions
			}

			// TODO: handle relationships more optimally
			_relationshipsRequiringDocuments.addAll(relationships);
			checkRelationshipsRequiringDocuments(record);

			_logger.info("Save changes initiated. Pending documents (create, remove): " + pendingCreateDocuments.size() + ", " + pendingRemoveDocuments.size());
		}

		private function checkRelationshipsRequiringDocuments(record:Record):void
		{
			for each (var relationship:Relationship in relationshipsRequiringDocuments)
			{
				if (relationship.relatesFrom.pendingAction == null && relationship.relatesTo.pendingAction == null)
				{
					relationshipsRequiringDocuments.removeItemAt(relationshipsRequiringDocuments.getItemIndex(relationship));
					pendingRelateDocuments.addItem(relationship);
					relateDocuments(record, relationship);
				}
			}
		}

		private function getDocumentXml(document:IDocument):String
		{
			// get the appropriate service that can convert this document type to XML
			var service:DocumentStorageServiceBase = _healthRecordServiceFacade.getService(document.meta.type);
			return service.marshallToXml(document);
		}

		override protected function deleteDocumentCompleteHandler(event:IndivoClientEvent,
																  responseXml:XML,
																  healthRecordServiceRequestDetails:HealthRecordServiceRequestDetails):void
		{
			super.deleteDocumentCompleteHandler(event, responseXml, healthRecordServiceRequestDetails);
			finishRemove(responseXml, healthRecordServiceRequestDetails);
		}

		override protected function voidDocumentCompleteHandler(event:IndivoClientEvent,
																responseXml:XML,
																healthRecordServiceRequestDetails:HealthRecordServiceRequestDetails):void
		{
			super.voidDocumentCompleteHandler(event, responseXml, healthRecordServiceRequestDetails);
			finishRemove(responseXml, healthRecordServiceRequestDetails);
		}

		private function finishRemove(responseXml:XML,
									  healthRecordServiceRequestDetails:HealthRecordServiceRequestDetails):void
		{
			var document:IDocument = healthRecordServiceRequestDetails.document;
			if (document == null)
				throw new Error("Document not specified on the HealthRecordServiceRequestDetails. Unable to finish remove operation.");

			var record:Record = healthRecordServiceRequestDetails.record;
			if (record == null)
				throw new Error("Record not specified on the HealthRecordServiceRequestDetails. Unable to finish remove operation.");

			document.pendingAction = null;
			pendingRemoveDocuments.remove(document.meta.id);
			record.completeDocumentsById.remove(document.meta.id);
			record.originalDocumentsById.remove(document.meta.id);

			// eliminate any "standard" references to the document that was removed
			for each (var relationship:Relationship in document.relatesTo)
			{
				if (relationship.relatesTo != null)
				{
					var otherDocument:ArrayCollection = relationship.relatesTo.isRelatedFrom;
					if (otherDocument.contains(relationship))
					{
						otherDocument.removeItemAt(otherDocument.getItemIndex(relationship));
					}
				}
			}

			// TODO: eliminate any "special" references to the document that was removed; currently we are removing relationships from document.isRelatedFrom, but not, for example, medicationScheduleItem.adherenceItems
		}

		override protected function createDocumentCompleteHandler(event:IndivoClientEvent,
																  responseXml:XML,
																  healthRecordServiceRequestDetails:HealthRecordServiceRequestDetails):void
		{
			var document:IDocument = healthRecordServiceRequestDetails.document;
			if (document == null)
				throw new Error("Document not specified on the HealthRecordServiceRequestDetails. Unable to finish remove operation.");

			document.pendingAction = null;
			pendingCreateDocuments.remove(document.meta.id);

			var failureWarning:String;
			if (responseXml.name() != "Document")
			{
				failureWarning = "Event from document creation was Complete, but response XML is not a Document.";
			}
			else if (!responseXml.hasOwnProperty("@id"))
			{
				failureWarning = "Event from document creation was Complete, but response XML does not have an id attribute.";
			}
			else if (!responseXml.hasOwnProperty("@type"))
			{
				failureWarning = "Event from document creation was Complete, but response XML does not have a type attribute.";
			}
			else if (responseXml.@type.toString() == "")
			{
				failureWarning = "Document was created (id = " + responseXml.@id.toString() + "), but has no type " +
							 "(expected " + document.meta.type + "). XML of submitted document may be incompatible with schema on server. You may want to delete the document and try again.";
			}
			else if (document.meta.type != responseXml.@type.toString())
			{
				failureWarning = "Unexpected response. Document was created (id = " + responseXml.@id.toString() + "), but has the wrong type " +
							 "(expected " + document.meta.type + ", actual " + responseXml.@type.toString() + "). You may want to delete the document and try again.";
			}

			var record:Record = healthRecordServiceRequestDetails.record;
			if (record == null)
				throw new Error("Record not specified on the HealthRecordServiceRequestDetails. Unable to finish remove operation.");

			var documentCollection:DocumentCollectionBase = record.documentCollections.getItem(document.meta.type);
			if (!documentCollection)
				throw new Error("Failed to get document collection for document type " + document.meta.type);

			// We now have the "real" id of the document, but the OLD id of the document was used as the key in various collections.
			// Using the OLD id of the created document, remove the document from the appropriate collections
			var oldId:String = document.meta.id;
			record.completeDocumentsById.remove(oldId);
			record.currentDocumentsById.remove(oldId);

			if (failureWarning)
			{
				documentCollection.removeDocument(document);
				_logger.warn(failureWarning + " Submitted document XML: " + event.requestXml + " Response: " + responseXml);
				return;
			}

			// update the document to use it's new id
			document.meta.id = responseXml.@id.toString();

			// Let the associated IDocumentCollection on the record handle the updated id (default behavior is to remove and re-add)
			documentCollection.handleUpdatedId(oldId, document);

			// Re-add the document to the record
			record.originalDocumentsById[document.meta.id] = document;
			record.completeDocumentsById[document.meta.id] = document;
			record.currentDocumentsById[document.meta.id] = document;

			// update any "standard" references to the document that was added
			for each (var relationship:Relationship in document.relatesTo)
			{
				relationship.relatesFromId = document.meta.id;
			}
			for each (relationship in document.isRelatedFrom)
			{
				relationship.relatesToId = document.meta.id;
			}

			// TODO: updateSpecialRelationships ?
//			documentCollection.updateSpecialRelationships(document);

			super.createDocumentCompleteHandler(event, responseXml, healthRecordServiceRequestDetails);

			// TODO: handle relationships more optimally
			checkRelationshipsRequiringDocuments(record);
		}

		override protected function relateDocumentsCompleteHandler(event:IndivoClientEvent, responseXml:XML,
																   healthRecordServiceRequestDetails:HealthRecordServiceRequestDetails):void
		{
			var relationship:Relationship = healthRecordServiceRequestDetails.customData as Relationship;
			if (relationship == null)
				throw new Error("Relationship not specified on the HealthRecordServiceRequestDetails. Unable to finish relate documents operation.");

			var failureWarning:String;
			if (responseXml.name() != "ok")
			{
				failureWarning = "Event from relate documents was Complete, but response XML is not ok.";
			}

			// remove the appropriate relationship from pendingRelateDocuments
			for each (var pendingRelationship:Relationship in pendingRelateDocuments)
			{
				if (pendingRelationship == relationship)
				{
					relationship.pendingAction = null;
					pendingRelateDocuments.removeItemAt(pendingRelateDocuments.getItemIndex(relationship));
				}
			}

			super.relateDocumentsCompleteHandler(event, responseXml, healthRecordServiceRequestDetails);
		}

		override protected function handleError(event:IndivoClientEvent, errorStatus:String,
												healthRecordServiceRequestDetails:HealthRecordServiceRequestDetails):Boolean
		{
			return super.handleError(event, errorStatus, healthRecordServiceRequestDetails);
		}

		public function get pendingCreateDocuments():HashMap
		{
			return _pendingCreateDocuments;
		}

		public function get pendingRemoveDocuments():HashMap
		{
			return _pendingRemoveDocuments;
		}

		public function get relationshipsRequiringDocuments():ArrayCollection
		{
			return _relationshipsRequiringDocuments;
		}

		public function get pendingRelateDocuments():ArrayCollection
		{
			return _pendingRelateDocuments;
		}
	}
}