/**
 * CallAnchorWebhookService
 * Receives a call from CallAnchor, finds the matching record (e.g. Lead) by phone,
 * and logs an activity (e.g. Task) on it.
 *
 *   POST /services/apexrest/CallAnchorWebhook/
 *
 * Sections:
 *   1. SETTINGS           - all object and field names live here
 *   2. ENDPOINT           - entry point + error handling
 *   3. READ PAYLOAD       - check input, build values
 *   4. FIND RECORD + LOG  - the business logic
 *   5. REUSABLE HELPERS   - work with ANY object (public, so other classes can use them)
 *   6. SMALL UTILITIES    - errors, response, conversions
 */
@RestResource(urlMapping='/CallAnchorWebhook/*')
global with sharing class V1_CallAnchorWebhookService {

    // =================================================================================
    //  1. SETTINGS - change objects and fields here only
    // =================================================================================

    // Record the call belongs to (e.g. Lead__c, Lead, Contact)
    private static final String PRIMARY_OBJECT = 'Lead__c';

    // Phone fields to check - a record matches if ANY of them contains the number
    private static final List<String> PHONE_FIELDS = new List<String>{
        'Primary_Mobile__c'
    };

    // Activity that logs the call (e.g. Task, Event, or a custom object)
    private static final String ACTIVITY_OBJECT = 'Task';

    // Record not found:  true = create a new one,  false = return an error (404)
    private static final Boolean CREATE_IF_NOT_FOUND = true;

    /*
     * Activity field => value key.   Available value keys:
     *
     *   From "call":        callId, callType, agentName, agentNumber, startedAt, calleeName,
     *                       calleePhone, phone (cleaned 10 digits), recordingUrl, dispositionNote,
     *                       durationSeconds, dispositionLabel, dispositionScheduledAt
     *   From the root:      event, hasRecording, submittedAt
     *   Calculated:         subject, status, activityDate
     *   From "disposition.fields":  ANY key, exactly as sent
     *                       e.g. 'note', 'outcome', 'scheduled-at', 'project-name-3'
     *
     * Values are converted to the field's type automatically (text, number, date, date/time, checkbox).
     * The link to the record is set automatically from recordId (no need to map it here).
     */
    private static final Map<String, String> ACTIVITY_FIELDS = new Map<String, String>{
        'Subject'               => 'subject',
        'Status'                => 'status',
        'ActivityDate'          => 'activityDate',
        'CallDurationInSeconds' => 'durationSeconds',
        'recordingUrl__c'       => 'recordingUrl',
        'Audio_File__c'         => 'recordingUrl',
        'Call_Disposition__c'   => 'dispositionLabel',
        'outcome__c'            => 'outcome',
        'note__c'               => 'note',
        'scheduled_At__c'       => 'scheduled-at'
        // Custom disposition key example:
        // 'Project_Name__c'    => 'project-name-3'
    };

    // New record field => value key (only used when CREATE_IF_NOT_FOUND = true)
    private static final Map<String, String> NEW_RECORD_FIELDS = new Map<String, String>{
        'Name'              => 'calleeName',
        'Primary_Mobile__c' => 'phone'
    };

    // =================================================================================
    //  2. ENDPOINT
    // =================================================================================

    @HttpPost
    global static void doPost() {
        try {
            Map<String, Object> values = readPayload();
            Map<String, Object> result = logCall(values);
            send(201, result);

        } catch (CallException e) {
            send(e.status, errorBody(e.code, e.getMessage()));          // our own checks

        } catch (DmlException e) {
            send(422, errorBody('SAVE_FAILED', e.getDmlMessage(0)));    // validation rule, required field...

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, e.getMessage() + '\n' + e.getStackTraceString());
            send(500, errorBody('UNEXPECTED_ERROR', e.getMessage()));
        }
    }

    // =================================================================================
    //  3. READ PAYLOAD
    // =================================================================================

    private static Map<String, Object> readPayload() {
        Blob body = RestContext.request.requestBody;
        if (body == null || body.size() == 0) {
            throw fail(400, 'EMPTY_BODY', 'Request body is empty.');
        }

        // Split the JSON into its three parts: root, call, disposition(.fields)
        Map<String, Object> root;
        Map<String, Object> call;
        Map<String, Object> disposition;
        Map<String, Object> fields;
        try {
            root        = (Map<String, Object>) JSON.deserializeUntyped(body.toString());
            call        = (Map<String, Object>) root.get('call');
            disposition = (Map<String, Object>) root.get('disposition');
            fields      = (disposition == null) ? null : (Map<String, Object>) disposition.get('fields');
        } catch (Exception e) {
            throw fail(400, 'INVALID_JSON', 'Request body is not valid JSON.');
        }
        if (call == null) {
            throw fail(400, 'MISSING_CALL', '"call" is required.');
        }
        if (disposition == null) disposition = new Map<String, Object>();
        if (fields == null)      fields      = new Map<String, Object>();

        // Required: a valid phone number
        String phone = cleanPhone(text(call.get('calleePhone')));
        if (phone == null) {
            throw fail(400, 'INVALID_PHONE', 'call.calleePhone is missing or not a valid 10-digit number.');
        }

        // Standard fields
        String   callType  = text(call.get('callType'));
        Datetime startedAt = toDatetime(call.get('startedAt'), 'call.startedAt');

        Map<String, Object> values = new Map<String, Object>{
            // from "call"
            'callId'                 => call.get('id'),
            'callType'               => callType,
            'agentName'              => call.get('agentName'),
            'agentNumber'            => call.get('agentNumber'),
            'startedAt'              => call.get('startedAt'),
            'calleeName'             => call.get('calleeName'),
            'calleePhone'            => call.get('calleePhone'),
            'phone'                  => phone,
            'recordingUrl'           => call.get('recordingUrl'),
            'dispositionNote'        => call.get('dispositionNote'),
            'durationSeconds'        => call.get('durationSeconds'),
            'dispositionLabel'       => call.get('dispositionLabel'),
            'dispositionScheduledAt' => call.get('dispositionScheduledAt'),
            // from the root
            'event'                  => root.get('event'),
            'hasRecording'           => root.get('hasRecording'),
            'submittedAt'            => disposition.get('submittedAt'),
            // calculated
            'subject'                => String.isBlank(callType) ? 'Call Log' : 'Call - ' + callType,
            'status'                 => 'Completed',
            'activityDate'           => startedAt != null ? startedAt.date() : Date.today()
        };

        // Custom fields: every key in disposition.fields is added as-is.
        // A standard key with the same name is never overwritten.
        for (String key : fields.keySet()) {
            if (!values.containsKey(key)) {
                values.put(key, fields.get(key));
            }
        }
        return values;
    }

    // =================================================================================
    //  4. FIND RECORD + LOG ACTIVITY
    // =================================================================================

    private static Map<String, Object> logCall(Map<String, Object> values) {
        Savepoint sp = Database.setSavepoint();     // if the activity fails, a new record is undone too
        try {
            Id recordId = findOrCreateRecord(values);

            SObject activity = createActivity(ACTIVITY_OBJECT, recordId, ACTIVITY_FIELDS, values);

            return new Map<String, Object>{ 'success' => true, 'activityId' => activity.Id, 'recordId' => recordId };
        } catch (Exception e) {
            Database.rollback(sp);
            throw e;
        }
    }

    private static Id findOrCreateRecord(Map<String, Object> values) {
        String phone = (String) values.get('phone');

        List<SObject> records = findByPhone(PRIMARY_OBJECT, PHONE_FIELDS, phone);

        // Found: use it. If several match, the most recently updated one is used.
        if (!records.isEmpty()) {
            return records[0].Id;
        }

        // Not found: either stop, or create a new record
        if (!CREATE_IF_NOT_FOUND) {
            throw fail(404, 'RECORD_NOT_FOUND', 'No ' + PRIMARY_OBJECT + ' found for ' + phone + '.');
        }
        return createRecord(PRIMARY_OBJECT, NEW_RECORD_FIELDS, values).Id;
    }

    // =================================================================================
    //  5. REUSABLE HELPERS - work with ANY object (Lead__c, Contact, Task, ...)
    // =================================================================================

    /**
     * Finds records where ANY of the phone fields contains the number. Newest record comes first.
     * Example: findByPhone('Contact', new List<String>{ 'MobilePhone', 'Phone' }, '9876543210')
     */
    public static List<SObject> findByPhone(String objectName, List<String> phoneFields, String phone) {
        // Builds: Field1 LIKE :phoneLike OR Field2 LIKE :phoneLike ...
        List<String> conditions = new List<String>();
        for (String field : phoneFields) {
            conditions.add(field + ' LIKE :phoneLike');
        }

        String query = 'SELECT Id FROM ' + objectName
                     + ' WHERE ' + String.join(conditions, ' OR ')
                     + ' ORDER BY LastModifiedDate DESC LIMIT 10';

        return Database.queryWithBinds(query,
            new Map<String, Object>{ 'phoneLike' => '%' + phone + '%' },
            AccessLevel.USER_MODE);
    }

    /**
     * Creates a record of any object.
     * fieldMap = field API name => key in values
     * Example: { 'Subject' => 'subject' } puts values.get('subject') into Task.Subject
     */
    public static SObject createRecord(String objectName, Map<String, String> fieldMap, Map<String, Object> values) {
        SObject record = buildRecord(objectName, fieldMap, values);
        insert as user record;
        return record;
    }

    /**
     * Creates an activity (Task, Event or custom object) linked to recordId.
     * The link field is picked automatically:
     *   Task / Event + Lead or Contact  -> WhoId
     *   Task / Event + any other object -> WhatId
     *   Custom activity object          -> its lookup field that points to the record's object
     */
    public static SObject createActivity(String activityObject, Id recordId, Map<String, String> fieldMap, Map<String, Object> values) {
        SObject activity = buildRecord(activityObject, fieldMap, values);
        activity.put(linkField(activityObject, recordId), recordId);
        insert as user activity;
        return activity;
    }

    /**
     * Cleans a phone number down to 10 digits. Returns null if it isn't valid.
     *   "+91 98765-43210" -> "9876543210"
     *   "09876543210"     -> "9876543210"
     *   "0091 9876543210" -> "9876543210"
     */
    public static String cleanPhone(String phone) {
        if (String.isBlank(phone)) {
            return null;
        }
        String digits = phone.replaceAll('[^0-9]', '');     // keep digits only

        if (digits.length() < 10 || digits.length() > 14) {
            return null;                                      // too short or too long
        }
        return digits.right(10);                              // drop +91 / 0 / 0091
    }

    /** Builds (does not insert) a record from a field map, converting each value to the field's type. */
    private static SObject buildRecord(String objectName, Map<String, String> fieldMap, Map<String, Object> values) {
        Schema.SObjectType objectType = Schema.getGlobalDescribe().get(objectName);
        Map<String, Schema.SObjectField> objectFields = objectType.getDescribe().fields.getMap();
        SObject record = objectType.newSObject();

        for (String field : fieldMap.keySet()) {
            Object value = values.get(fieldMap.get(field));
            if (value == null || String.isBlank(String.valueOf(value))) {
                continue;                                     // nothing sent - leave the field empty
            }
            if (!objectFields.containsKey(field)) {
                throw fail(500, 'CONFIG_ERROR', objectName + '.' + field + ' does not exist.');
            }
            Schema.DisplayType fieldType = objectFields.get(field).getDescribe().getType();
            record.put(field, convert(value, fieldType, fieldMap.get(field)));
        }
        return record;
    }

    /** Converts a payload value to what the field expects. */
    private static Object convert(Object value, Schema.DisplayType fieldType, String key) {
        String textValue = String.valueOf(value).trim();
        Object result = textValue;                            // default: text
        try {
            switch on fieldType {
                when DATE                      { result = (value instanceof Date) ? value : toDatetime(textValue, key).date(); }
                when DATETIME                  { result = toDatetime(textValue, key); }
                when INTEGER                   { result = Decimal.valueOf(textValue).intValue(); }
                when DOUBLE, CURRENCY, PERCENT { result = Decimal.valueOf(textValue); }
                when BOOLEAN                   { result = Boolean.valueOf(textValue); }
                when REFERENCE, ID             { result = value; }
            }
        } catch (CallException e) {
            throw e;
        } catch (Exception e) {
            throw fail(400, 'INVALID_VALUE', '"' + textValue + '" (' + key + ') is not a valid ' + fieldType + '.');
        }
        return result;
    }

    /** Finds the field on the activity object that can point to recordId. */
    private static String linkField(String activityObject, Id recordId) {
        Schema.SObjectType recordType = recordId.getSObjectType();

        if (activityObject == 'Task' || activityObject == 'Event') {
            return (recordType == Lead.SObjectType || recordType == Contact.SObjectType) ? 'WhoId' : 'WhatId';
        }
        for (Schema.SObjectField field : Schema.getGlobalDescribe().get(activityObject).getDescribe().fields.getMap().values()) {
            if (field.getDescribe().getReferenceTo().contains(recordType)) {
                return field.getDescribe().getName();
            }
        }
        throw fail(500, 'CONFIG_ERROR', activityObject + ' has no lookup to ' + recordType + '.');
    }

    // =================================================================================
    //  6. SMALL UTILITIES
    // =================================================================================

    /** Error with an HTTP status and a short code. */
    public class CallException extends Exception {
        public Integer status;
        public String  code;
    }

    private static CallException fail(Integer status, String code, String message) {
        CallException e = new CallException(message);
        e.status = status;
        e.code   = code;
        return e;
    }

    /** { "success": false, "error": { "code": "...", "message": "..." } } */
    private static Map<String, Object> errorBody(String code, String message) {
        return new Map<String, Object>{
            'success' => false,
            'error'   => new Map<String, Object>{ 'code' => code, 'message' => message }
        };
    }

    private static void send(Integer status, Map<String, Object> body) {
        RestResponse res = RestContext.response;
        res.statusCode = status;
        res.addHeader('Content-Type', 'application/json');
        res.responseBody = Blob.valueOf(JSON.serialize(body));
    }

    /** Any JSON value -> String (null stays null). */
    private static String text(Object value) {
        return value == null ? null : String.valueOf(value);
    }

    /** ISO-8601 text like "2026-09-25T13:38:09.478Z" -> Datetime (null stays null). */
    private static Datetime toDatetime(Object value, String fieldName) {
        if (value == null || String.isBlank(String.valueOf(value))) {
            return null;
        }
        try {
            return (Datetime) JSON.deserialize('"' + value + '"', Datetime.class);
        } catch (Exception e) {
            throw fail(400, 'INVALID_DATE', fieldName + ' must be an ISO-8601 date/time.');
        }
    }
}