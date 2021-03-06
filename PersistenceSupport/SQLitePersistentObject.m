// ----------------------------------------------------------------------
// Part of the SQLite Persistent Objects for Cocoa and Cocoa Touch
//
// (c) 2008 Jeff LaMarche (jeff_Lamarche@mac.com)
// ----------------------------------------------------------------------
// This code may be used without restriction in any software, commercial,
// free, or otherwise. There are no attribution requirements, and no
// requirement that you distribute your changes, although bugfixes and 
// enhancements are welcome.
// 
// If you do choose to re-distribute the source code, you must retain the
// copyright notice and this license information. I also request that you
// place comments in to identify your changes.
//
// For information on how to use these classes, take a look at the 
// included eadme.txt file
// ----------------------------------------------------------------------

#import "SQLitePersistentObject.h"
#import "SQLiteInstanceManager.h"
#import "NSString-SQLiteColumnName.h"
#import "NSObject-SQLitePersistence.h"
#import "NSString-UppercaseFirst.h"

id findByMethodImp(id self, SEL _cmd, id value)
{
	NSString *methodBeingCalled = [NSString stringWithCString:sel_getName(_cmd)];
	
	NSRange theRange = NSMakeRange(6, [methodBeingCalled length] - 7);
	NSString *property = [[methodBeingCalled substringWithRange:theRange] stringByLowercasingFirstLetter];
	
	NSMutableString *queryCondition = [NSMutableString stringWithFormat:@"WHERE %@ = ", [property stringAsSQLColumnName]];
	if (![value isKindOfClass:[NSNumber class]])
		[queryCondition appendString:@"'"];
	
	if ([value conformsToProtocol:@protocol(SQLitePersistence)])
	{
		if ([[value class] shouldBeStoredInBlob])
		{
			NSLog(@"*** Can't search on BLOB fields");
			return nil;
		}
		else
			[queryCondition appendString:[value sqlColumnRepresentationOfSelf]];
	}
	else
	{
		[queryCondition appendString:[value stringValue]];
	}
	
	if (![value isKindOfClass:[NSNumber class]])	
		[queryCondition appendString:@"'"];	
	
	return [self findByCriteria:queryCondition];
}



@interface SQLitePersistentObject (private)
+ (void)tableCheck;
- (void)setPk:(int)newPk;
+ (NSString *)classNameForTableName:(NSString *)theTable;
+ (void)setUpDynamicMethods;
@end
@interface SQLitePersistentObject (private_memory)
+ (void)registerObjectInMemory:(SQLitePersistentObject *)theObject;
+ (void)unregisterObject:(SQLitePersistentObject *)theObject;
- (NSString *)memoryMapKey;
@end

NSMutableDictionary *objectMap;

@implementation SQLitePersistentObject
#pragma mark Public Class Methods
+(NSArray *)indices
{
	return nil;
}
+(SQLitePersistentObject *)findFirstByCriteria:(NSString *)criteriaString;
{
	NSArray *array = [self findByCriteria:criteriaString];
	if (array != nil)
		if ([array count] > 0)
			return [array objectAtIndex:0];
	return  nil;
}
+(SQLitePersistentObject *)findByPK:(int)inPk
{
	return [self findFirstByCriteria:[NSString stringWithFormat:@"WHERE pk = %d", inPk]];
}
+(NSArray *)findByCriteria:(NSString *)criteriaString
{
	
	[[self class] tableCheck];
	NSMutableArray *ret = [NSMutableArray array];
	NSDictionary *theProps = [self propertiesWithEncodedTypes];
	sqlite3 *database = [[SQLiteInstanceManager sharedManager] database];
	
	NSString *query = [NSString stringWithFormat:@"SELECT * FROM %@ %@", [[self class] tableName], criteriaString];
	sqlite3_stmt *statement;
	if (sqlite3_prepare_v2( database, [query UTF8String], -1, &statement, NULL) == SQLITE_OK)
	{
		while (sqlite3_step(statement) == SQLITE_ROW)
		{
			
			BOOL foundInMemory = NO;
			
			id oneItem = [[[self class] alloc] init];
			
			int i;
			for (i=0; i <  sqlite3_column_count(statement); i++)
			{
				NSString *colName = [NSString stringWithUTF8String:sqlite3_column_name(statement, i)];
				if ([colName isEqualToString:@"pk"])
				{
					[oneItem setPk:sqlite3_column_int(statement, i)];
				/*	if([[self className] compare:@"Budget" options:NSCaseInsensitiveSearch] != NSOrderedSame)
					{
					NSString *mapKey = [oneItem memoryMapKey];
					if ([[objectMap allKeys] containsObject:mapKey])
					{
						SQLitePersistentObject *testObject = [objectMap objectForKey:mapKey];
						if (testObject != nil)
						{
							// Object is already loaded, release object, and use the one in memory
							[oneItem release];
							// Retain it so that the object count matches what we had before
							oneItem = [testObject retain];
							// end the loop so we don't bother reading any more data
							i = sqlite3_column_count(statement) + 1;
							// Mark Found in memory so we don't try and load xref tables
							foundInMemory = YES;
						}
					}
					}
				 */
				}
				else
				{
					
					
					NSString *propName = [colName stringAsPropertyString];
					
					NSString *colType = [theProps valueForKey:propName];
					if (colType == nil)
						break;
					if ([colType isEqualToString:@"i"] || // int
						[colType isEqualToString:@"l"] || // long
						[colType isEqualToString:@"q"] || // long long
						[colType isEqualToString:@"s"] || // short
						[colType isEqualToString:@"B"] )  // bool or _Bool
						
					{
						long long value = sqlite3_column_int64(statement, i);
						NSNumber *colValue = [NSNumber numberWithLongLong:value];
						[oneItem setValue:colValue forKey:propName];
					}
					else if  ([colType isEqualToString:@"I"] || // unsigned int
							  [colType isEqualToString:@"L"] || // usigned long
							  [colType isEqualToString:@"Q"] || // unsigned long long
							  [colType isEqualToString:@"S"]) // unsigned short
					{
						unsigned long long value = sqlite3_column_int64(statement, i);
						NSNumber *colValue = [NSNumber numberWithUnsignedLongLong:value];
						[oneItem setValue:colValue forKey:propName];
					}
					else if ([colType isEqualToString:@"f"] || // float
							 [colType isEqualToString:@"d"] || // double
							 [colType isEqualToString:@"NSNumber"] ) // HACK: Somehow we're getting NSNumbers in the DB 
					{
						NSNumber *colVal = [NSNumber numberWithFloat:sqlite3_column_double(statement, i)];
						[oneItem setValue:colVal forKey:propName];
					}
					else if ([colType hasPrefix:@"@"])
					{
						NSString *className = [colType substringWithRange:NSMakeRange(2, [colType length]-3)];
						Class propClass = objc_lookUpClass([className UTF8String]);
						
						if ([propClass isSubclassOfClass:[SQLitePersistentObject class]])
						{
							NSString *objMemoryMapKey = [NSString stringWithCString:(const char *)sqlite3_column_text(statement, i)];
							NSArray *parts = [objMemoryMapKey componentsSeparatedByString:@"-"];
							NSString *classString = [parts objectAtIndex:0];
							int fk = [[parts objectAtIndex:1] intValue];
							Class propClass = objc_lookUpClass([classString UTF8String]);
							id fkObj = [propClass findByCriteria:[NSString stringWithFormat:@"WHERE pk = %d", fk]];
							[oneItem setValue:fkObj forKey:propName];
						}
						else if ([propClass shouldBeStoredInBlob])
						{
							// TODO: Don't want to support this right now...
							
			 /*
							const char * rawData = sqlite3_column_blob(statement, i);
							int rawDataLength = sqlite3_column_bytes(statement, i);
							NSData *data = [NSData dataWithBytes:rawData length:rawDataLength];
							[data writeToFile:@"/Users/jeff/Desktop/intermediate" atomically:YES];
							id colData = [propClass objectWithSQLBlobRepresentation:data];
							[oneItem setValue:colData forKey:propName];
							 */
						}
						else
						{
							id colData = [[propClass objectWithSqlColumnRepresentation:[NSString stringWithCString:(const char *)sqlite3_column_text(statement, i) encoding:NSUTF8StringEncoding]] retain];
							[oneItem setValue:colData forKey:propName];
							[colData release];
							[propClass release];
						}
					}
					
				}
			}
			
			// Disabling memory cache for now - makes the user think the data wasn't saved
			//if (!foundInMemory)
			if(true)
			{
				
				
				// Loop through properties and look for collections classes
				for (NSString *propName in theProps)
				{
					NSString *propType = [theProps objectForKey:propName];
					if ([propType hasPrefix:@"@"])
					{
						NSString *className = [propType substringWithRange:NSMakeRange(2, [propType length]-3)];
						if (isNSSetType(className) || isNSArrayType(className) || isNSDictionaryType(className))
						{
							if (isNSSetType(className))
							{
								NSMutableSet *set = [NSMutableSet set];
								[oneItem setValue:set forKey:propName];
								/*
								 parent_pk INTEGER, fk INTEGER, fk_table_name TEXT, object_data TEXT
								 */
								NSString *setQuery = [NSString stringWithFormat:@"SELECT fk, fk_table_name, object_data, object_class FROM %@_%@ WHERE parent_pk = %d", [[self class] tableName], [propName stringAsSQLColumnName], [oneItem pk]];
								sqlite3_stmt *setStmt;
								if (sqlite3_prepare_v2(database, [setQuery UTF8String], -1, &setStmt, NULL) == SQLITE_OK)
								{
									while (sqlite3_step(setStmt) == SQLITE_ROW)
									{
										int fk = sqlite3_column_int(setStmt, 0);
										
										if (fk > 0)
										{
											const char *fkTableNameRaw = (const char *)sqlite3_column_text(setStmt, 1);
											NSString *fkTableName = (fkTableNameRaw == nil) ? nil : [NSString stringWithCString:fkTableNameRaw];
											NSString *propClassName = [[self class] classNameForTableName:fkTableName];
											Class propClass = objc_lookUpClass([propClassName UTF8String]);
											id oneObject = [propClass findFirstByCriteria:[NSString stringWithFormat:@"where pk = %d", fk]];
											if (oneObject != nil)
												[set addObject:oneObject];
										}
										else
										{
											
											const char *objectClassRaw = (const char *)sqlite3_column_text(setStmt, 3);
											NSString *objectClassName = (objectClassRaw == nil) ? nil : [NSString stringWithCString:objectClassRaw];
											
											Class objectClass = objc_lookUpClass([objectClassName UTF8String]);
											if ([objectClass shouldBeStoredInBlob])
											{
												NSData *data = [NSData dataWithBytes:sqlite3_column_blob(setStmt, 3) length:sqlite3_column_bytes(setStmt, 3)];
												id theObject = [objectClass objectWithSQLBlobRepresentation:data];
												[set addObject:theObject];
											}
											else
											{
												const char *objectDataRaw = (const char *)sqlite3_column_text(setStmt, 2);
												NSString *objectData = (objectDataRaw == nil) ? nil : [NSString stringWithCString:objectDataRaw];
												
												id theObject = [objectClass objectWithSqlColumnRepresentation:objectData];
												[set addObject:theObject];
											}
										}
									}
								}
								sqlite3_finalize(setStmt);
							}
							else if (isNSArrayType(className))
							{
								NSMutableArray *array = [NSMutableArray array];
								[oneItem setValue:array forKey:propName];
								
								NSString *arrayQuery = [NSString stringWithFormat:@"SELECT fk, fk_table_name, object_data, object_class FROM %@_%@ WHERE parent_pk = %d order by array_index", [[self class] tableName], [propName stringAsSQLColumnName], [oneItem pk]];
								sqlite3_stmt *arrayStmt;
								if (sqlite3_prepare_v2(database, [arrayQuery UTF8String], -1, &arrayStmt, NULL) == SQLITE_OK)
								{
									while (sqlite3_step(arrayStmt) == SQLITE_ROW)
									{
										
										int fk = sqlite3_column_int(arrayStmt, 0);
										
										if (fk > 0)
										{
											const char *fkTableNameRaw = (const char *)sqlite3_column_text(arrayStmt, 1);
											NSString *fkTableName = (fkTableNameRaw == nil) ? nil : [NSString stringWithCString:fkTableNameRaw];
											NSString *propClassName = [[self class] classNameForTableName:fkTableName];
											Class propClass = objc_lookUpClass([propClassName UTF8String]);
											id oneObject = [propClass findFirstByCriteria:[NSString stringWithFormat:@"where pk = %d", fk]];
											if (oneObject != nil)
												[array addObject:oneObject];
										}
										else
										{
											
											const char *objectClassRaw = (const char *)sqlite3_column_text(arrayStmt, 3);
											NSString *objectClassName = (objectClassRaw == nil) ? nil : [NSString stringWithCString:objectClassRaw];
											
											Class objectClass = objc_lookUpClass([objectClassName UTF8String]);
											if ([objectClass shouldBeStoredInBlob])
											{
												NSData *data = [NSData dataWithBytes:sqlite3_column_blob(arrayStmt, 3) length:sqlite3_column_bytes(arrayStmt, 3)];
												id theObject = [objectClass objectWithSQLBlobRepresentation:data];
												[array addObject:theObject];
											}
											else
											{
												const char *objectDataRaw = (const char *)sqlite3_column_text(arrayStmt, 2);
												NSString *objectData = (objectDataRaw == nil) ? nil : [NSString stringWithCString:objectDataRaw];
												
												id theObject = [objectClass objectWithSqlColumnRepresentation:objectData];
												if (theObject)
													[array addObject:theObject];
											}
										}
									}
								}
								sqlite3_finalize(arrayStmt);
							}
							else if (isNSDictionaryType(className))
							{
								NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
								[oneItem setValue:dictionary forKey:propName];
								/* parent_pk integer, dictionary_key TEXT, fk INTEGER, fk_table_name TEXT, object_data BLOB, object_class  */
								
								NSString *dictionaryQuery = [NSString stringWithFormat:@"SELECT dictionary_key, fk, fk_table_name, object_data, object_class FROM %@_%@ WHERE parent_pk = %d", [[self class] tableName], [propName stringAsSQLColumnName], [oneItem pk]];
								sqlite3_stmt *dictionaryStmt;
								if (sqlite3_prepare_v2(database, [dictionaryQuery UTF8String], -1, &dictionaryStmt, NULL) == SQLITE_OK)
								{
									while (sqlite3_step(dictionaryStmt) == SQLITE_ROW)
									{
										NSString *key = [NSString stringWithCString:(char *)sqlite3_column_text(dictionaryStmt, 0)];
										int fk = sqlite3_column_int(dictionaryStmt, 1);
										
										if (fk > 0)
										{
											const char *fkTableNameRaw = (const char *)sqlite3_column_text(dictionaryStmt, 2);
											NSString *fkTableName = (fkTableNameRaw == nil) ? nil : [NSString stringWithCString:fkTableNameRaw];
											NSString *propClassName = [[self class] classNameForTableName:fkTableName];
											Class propClass = objc_lookUpClass([propClassName UTF8String]);
											id oneObject = [propClass findFirstByCriteria:[NSString stringWithFormat:@"where pk = %d", fk]];
											if (oneObject != nil)
												[dictionary setObject:oneObject forKey:key];
										}
										else
										{
											
											const char *objectClassRaw = (const char *)sqlite3_column_text(dictionaryStmt, 4);
											NSString *objectClassName = (objectClassRaw == nil) ? nil : [NSString stringWithCString:objectClassRaw];
											
											Class objectClass = objc_lookUpClass([objectClassName UTF8String]);
											if ([objectClass shouldBeStoredInBlob])
											{
												NSData *data = [NSData dataWithBytes:sqlite3_column_blob(dictionaryStmt, 3) length:sqlite3_column_bytes(dictionaryStmt, 3)];
												id theObject = [objectClass objectWithSQLBlobRepresentation:data];
												if (theObject)
													[dictionary setObject:theObject forKey:key];
												
											}
											else
											{
												const char *objectDataRaw = (const char *)sqlite3_column_text(dictionaryStmt, 3);
												NSString *objectData = (objectDataRaw == nil) ? nil : [NSString stringWithCString:objectDataRaw];
												
												id theObject = [objectClass objectWithSqlColumnRepresentation:objectData];
												if (theObject != nil)
													[dictionary setObject:theObject forKey:key];
											}
										}
									}
								}
								sqlite3_finalize(dictionaryStmt);
							}
						}
					}
				}
			}
			[ret addObject:oneItem];
			[oneItem release];
		}
		sqlite3_finalize(statement);
	}else
	{
		NSString* errorMessage = [NSString stringWithUTF8String:sqlite3_errmsg(database)];
		NSLog(errorMessage);
	}
	
	
	return ret;
}
+(NSDictionary *)propertiesWithEncodedTypes
{
	//	static NSMutableDictionary *encodedTypesByClass = nil;
	//	
	//	if (encodedTypesByClass == nil)
	//		encodedTypesByClass = [[NSMutableDictionary alloc] init];
	//	
	//	if ([[encodedTypesByClass allKeys] containsObject:[self className]])
	//		return [encodedTypesByClass objectForKey:[self className]];
	
	// DO NOT use a static variable to cache this, it will cause problem with subclasses of classes that are subclasses of SQLitePersistentObject
	
	// Recurse up the classes, but stop at NSObject. Each class only reports its own properties, not those inherited from its superclass
	NSMutableDictionary *theProps;
	
	if ([self superclass] != [NSObject class])
		theProps = (NSMutableDictionary *)[[self superclass] propertiesWithEncodedTypes];
	else
		theProps = [NSMutableDictionary dictionary];
	
	unsigned int outCount;
	
	
	objc_property_t *propList = class_copyPropertyList([self class], &outCount);
	int i;
	
	// Loop through properties and add declarations for the create
	for (i=0; i < outCount; i++)
	{
		objc_property_t * oneProp = propList + i;
		NSString *propName = [NSString stringWithCString:property_getName(*oneProp)];
		NSString *attrs = [NSString stringWithCString: property_getAttributes(*oneProp)];
		NSArray *attrParts = [attrs componentsSeparatedByString:@","];
		if (attrParts != nil)
		{
			if ([attrParts count] > 0)
			{
				NSString *propType = [[attrParts objectAtIndex:0] substringFromIndex:1];
				[theProps setObject:propType forKey:propName];
			}
		}
	}
	//	[encodedTypesByClass setValue:theProps forKey:[self className]];
	if(propList != NULL)
		free(propList);
	return theProps;	
}

+ (void)clearCache
{
	if(objectMap != nil)
		[objectMap removeAllObjects];
}

#pragma mark -
#pragma mark Public Instance Methods
-(int)pk
{
	return pk;
}
-(void)save
{
	[[self class] tableCheck];
	
	sqlite3 *database = [[SQLiteInstanceManager sharedManager] database];
	
	// If this object is new, we need to figure out the correct primary key value, 
	// which will be one higher than the current highest pk value in the table.
	if (pk < 0)
	{
		NSString *pkQuery = [NSString stringWithFormat:@"SELECT MAX(PK) FROM %@", [[self class] tableName]];
		sqlite3_stmt *statement;
		if (sqlite3_prepare_v2(database, [pkQuery UTF8String], -1, &statement, nil) == SQLITE_OK) 
		{
			if (sqlite3_step(statement) == SQLITE_ROW) 
				pk = sqlite3_column_int(statement, 0)+1;
			
		}
		else NSLog(@"Error determining next PK value in table %@", [[self class] tableName]);
		sqlite3_finalize(statement);
	}
	
	NSMutableString *updateSQL = [NSMutableString stringWithFormat:@"INSERT OR REPLACE INTO %@ (pk", [[self class] tableName]];
	
	NSMutableString *bindSQL = [NSMutableString string];
	
	NSDictionary *props = [[self class] propertiesWithEncodedTypes];
	for (NSString *propName in props)
	{
		NSString *propType = [[[self class] propertiesWithEncodedTypes] objectForKey:propName];
		NSString *className = @"";
		if ([propType hasPrefix:@"@"])
			className = [propType substringWithRange:NSMakeRange(2, [propType length]-3)];
		if (! (isNSSetType(className) || isNSArrayType(className) || isNSDictionaryType(className)))
		{
			[updateSQL appendFormat:@", %@", [propName stringAsSQLColumnName]];
			[bindSQL appendString:@", ?"];
		}
	}
	
	[updateSQL appendFormat:@") VALUES (?%@)", bindSQL];
	
	sqlite3_stmt *stmt;
	if (sqlite3_prepare_v2( database, [updateSQL UTF8String], -1, &stmt, nil) == SQLITE_OK)
	{
		int colIndex = 1;
		sqlite3_bind_int(stmt, colIndex++, pk);
		
		props = [[self class] propertiesWithEncodedTypes];
		for (NSString *propName in props)
		{
			NSString *propType = [[[self class] propertiesWithEncodedTypes] objectForKey:propName];
			//int colIndex = sqlite3_bind_parameter_index(stmt, [[propName stringAsSQLColumnName] UTF8String]);
			id theProperty = [self valueForKey:propName];
			if (theProperty == nil)
			{
				sqlite3_bind_null(stmt, colIndex++);
			}
			else if ([propType isEqualToString:@"i"] || // int
					 [propType isEqualToString:@"I"] || // unsigned int
					 [propType isEqualToString:@"l"] || // long
					 [propType isEqualToString:@"L"] || // usigned long
					 [propType isEqualToString:@"q"] || // long long
					 [propType isEqualToString:@"Q"] || // unsigned long long
					 [propType isEqualToString:@"s"] || // short
					 [propType isEqualToString:@"S"] || // unsigned short
					 [propType isEqualToString:@"B"] || // bool or _Bool
					 [propType isEqualToString:@"f"] || // float
					 [propType isEqualToString:@"d"] )  // double
			{
				sqlite3_bind_text(stmt, colIndex++, [[theProperty stringValue] UTF8String], -1, NULL);
			}	
			else if ([propType isEqualToString:@"c"] ||	// char
					 [propType isEqualToString:@"C"] ) // unsigned char
				
			{
				// ======================================
				// THESE DON'T WORK CURRENTLY
				//    do not use char, unsigned char, or
				//    char * in properties to be
				//    persisted
				// ======================================
				char oneChar = [[theProperty valueForKey:propName] charValue];
				NSString *theString = [NSString stringWithCharacters:(unichar *)&oneChar length:1];
				sqlite3_bind_text(stmt, colIndex, [theString UTF8String], -1, NULL);
			}
			else if ([propType hasPrefix:@"@"] ) // Object
			{
				NSString *className = [propType substringWithRange:NSMakeRange(2, [propType length]-3)];
				
				
				if (! (isNSSetType(className) || isNSArrayType(className) || isNSDictionaryType(className)))
				{
					
					if ([[theProperty class] isSubclassOfClass:[SQLitePersistentObject class]])
					{
						[theProperty save];
						sqlite3_bind_text(stmt, colIndex++, [[theProperty memoryMapKey] UTF8String], -1, NULL);
					}
					else if ([[theProperty class] shouldBeStoredInBlob])
					{
						NSData *data = [theProperty sqlBlobRepresentationOfSelf];
						sqlite3_bind_blob(stmt, colIndex++, [data bytes], [data length], NULL);
					}
					else
					{
						sqlite3_bind_text(stmt, colIndex++, [[theProperty sqlColumnRepresentationOfSelf] UTF8String], -1, NULL);
					}
				}
				else
				{
					// Too difficult to try and figure out what's changed, just wipe rows and re-insert the current data.
					NSString *xrefDelete = [NSString stringWithFormat:@"delete from %@_%@ where parent_pk = %d", [[self class] tableName], [propName stringAsSQLColumnName], pk];
					char *errmsg = NULL;
					if (sqlite3_exec (database, [xrefDelete UTF8String], NULL, NULL, &errmsg) != SQLITE_OK)
						NSLog(@"Error deleting child rows in xref table for array: %s", errmsg);
					sqlite3_free(errmsg);
					
					
					if (isNSArrayType(className))
					{
						int arrayIndex = 0;
						for (id oneObject in (NSArray *)theProperty)
						{
							if ([oneObject isKindOfClass:[SQLitePersistentObject class]])
							{
								[oneObject save];
								NSString *xrefInsert = [NSString stringWithFormat:@"insert into %@_%@ (parent_pk, array_index, fk, fk_table_name) values (%d, %d, %d, '%@')", [[self class] tableName], [propName stringAsSQLColumnName],  pk, arrayIndex++, [oneObject pk], [[oneObject class] tableName]];
								if (sqlite3_exec (database, [xrefInsert UTF8String], NULL, NULL, &errmsg) != SQLITE_OK)
									NSLog(@"Error inserting child rows in xref table for array: %s", errmsg);
								sqlite3_free(errmsg);
							}
							else 
							{
								if ([[oneObject class] canBeStoredInSQLite])
								{
									NSString *xrefInsert = [NSString stringWithFormat:@"insert into %@_%@ (parent_pk, array_index, object_data, object_class) values (%d, %d, ?, '%@')", [[self class] tableName], [propName stringAsSQLColumnName], pk, arrayIndex++, [oneObject className]];
									
									sqlite3_stmt *xStmt;
									if (sqlite3_prepare_v2( database, [xrefInsert UTF8String], -1, &xStmt, nil) == SQLITE_OK)
									{
										if ([[oneObject class] shouldBeStoredInBlob])
										{
											NSData *data = [oneObject sqlBlobRepresentationOfSelf];
											sqlite3_bind_blob(stmt, colIndex++, [data bytes], [data length], NULL);
										}
										else
										{
											if ([[oneObject class] shouldBeStoredInBlob])
											{
												NSData *data = [oneObject sqlBlobRepresentationOfSelf];
												sqlite3_bind_blob(stmt, colIndex++, [data bytes], [data length], NULL);
											}
											else
												sqlite3_bind_text(xStmt, 1, [[oneObject sqlColumnRepresentationOfSelf] UTF8String], -1, NULL);	
										}
										
										if (sqlite3_step(xStmt) != SQLITE_DONE)
											NSLog(@"Error inserting or updating cross-reference row");
										sqlite3_finalize(xStmt);
										//sqlite3_reset(xStmt);
									}
								}
								else 
									NSLog(@"Could not save object at array index: %d", arrayIndex++);
							}
						}
					}
					else if (isNSDictionaryType(className))
					{
						for (NSString *oneKey in (NSDictionary *)theProperty)
						{
							id oneObject = [(NSDictionary *)theProperty objectForKey:oneKey];
							if ([(NSObject *)oneObject isKindOfClass:[SQLitePersistentObject class]])
							{
								[(SQLitePersistentObject *)oneObject save];
								NSString *xrefInsert = [NSString stringWithFormat:@"insert into %@_%@ (parent_pk, dictionary_key, fk, fk_table_name) values (%d, '%@', %d, '%@')",  [[self class] tableName], [propName stringAsSQLColumnName], pk, oneKey, [(SQLitePersistentObject *)oneObject pk], [[oneObject class] tableName]];
								if (sqlite3_exec (database, [xrefInsert UTF8String], NULL, NULL, &errmsg) != SQLITE_OK)
									NSLog(@"Error inserting child rows in xref table for array: %s", errmsg);
								sqlite3_free(errmsg);
							}
							else
							{
								if ([[oneObject class] canBeStoredInSQLite])
								{
									NSString *xrefInsert = [NSString stringWithFormat:@"insert into %@_%@ (parent_pk, dictionary_key, object_data, object_class) values (%d, '%@', ?, '%@')", [[self class] tableName], [propName stringAsSQLColumnName], pk, oneKey, [oneObject className]];
									sqlite3_stmt *xStmt;
									if (sqlite3_prepare_v2( database, [xrefInsert UTF8String], -1, &xStmt, nil) == SQLITE_OK)
									{
										if ([[oneObject class] shouldBeStoredInBlob])
										{
											NSData *data = [oneObject sqlBlobRepresentationOfSelf];
											sqlite3_bind_blob(stmt, colIndex++, [data bytes], [data length], NULL);
										}
										else
											sqlite3_bind_text(xStmt, 1, [[oneObject sqlColumnRepresentationOfSelf] UTF8String], -1, NULL);
										if (sqlite3_step(xStmt) != SQLITE_DONE)
											NSLog(@"Error inserting or updating cross-reference row");
										sqlite3_finalize(xStmt);
										//sqlite3_reset(xStmt);
									}
								}
							}
						}
					}
					else // NSSet
					{
						for (id oneObject in (NSSet *)theProperty)
						{
							if ([oneObject isKindOfClass:[SQLitePersistentObject class]])
							{
								[oneObject save];
								NSString *xrefInsert = [NSString stringWithFormat:@"insert into %@_%@ (parent_pk, fk, fk_table_name) values (%d, %d, '%@')", [[self class] tableName], [propName stringAsSQLColumnName],  pk, [oneObject pk], [[oneObject class] tableName]];
								if (sqlite3_exec (database, [xrefInsert UTF8String], NULL, NULL, &errmsg) != SQLITE_OK)
									NSLog(@"Error inserting child rows in xref table for array: %s", errmsg);
								sqlite3_free(errmsg);
							}
							else
							{
								if ([[oneObject class] canBeStoredInSQLite])
								{
									NSString *xrefInsert = [NSString stringWithFormat:@"insert into %@_%@ (parent_pk, object_data, object_class) values (%d, ?, '%@')", [[self class] tableName], [propName stringAsSQLColumnName], pk, [oneObject className]];
									
									sqlite3_stmt *xStmt;
									if (sqlite3_prepare_v2( database, [xrefInsert UTF8String], -1, &xStmt, nil) == SQLITE_OK)
									{
										if ([[oneObject class] shouldBeStoredInBlob])
										{
											NSData *data = [oneObject sqlBlobRepresentationOfSelf];
											sqlite3_bind_blob(stmt, colIndex++, [data bytes], [data length], NULL);
										}
										else
											sqlite3_bind_text(xStmt, 1, [[oneObject sqlColumnRepresentationOfSelf] UTF8String], -1, NULL);
										if (sqlite3_step(xStmt) != SQLITE_DONE)
											NSLog(@"Error inserting or updating cross-reference row");
										sqlite3_finalize(xStmt);
										//sqlite3_reset(xStmt);
									}
								}
								else 
									NSLog(@"Could not save object from set");
							}
						}
					}
				}
			}
		}
		if (sqlite3_step(stmt) != SQLITE_DONE)
			NSLog(@"Error inserting or updating row");
		sqlite3_finalize(stmt);
		//sqlite3_reset(stmt);
	}
	// Can't register in memory map until we have PK, so do that now.
	if (![[objectMap allKeys] containsObject:[self memoryMapKey]])
		[[self class] registerObjectInMemory:self];
}
-(BOOL) existsInDB
{
	return pk >= 0;
}
-(void)deleteObject
{
	[self deleteObjectCascade:NO];
}

-(void)deleteObjectCascade:(BOOL)cascade
{
	BOOL tableChecked = NO;
	if (!tableChecked)
	{
		tableChecked = YES;
		[[self class] tableCheck];
		
		Class baseClass = objc_lookUpClass([[self className] UTF8String]);
		
		NSString *deleteQuery = [NSString stringWithFormat:@"DELETE FROM %@ WHERE pk = %d", [baseClass tableName], pk];
		sqlite3 *database = [[SQLiteInstanceManager sharedManager] database];
		char *errmsg = NULL;
		if (sqlite3_exec (database, [deleteQuery UTF8String], NULL, NULL, &errmsg) != SQLITE_OK)
			NSLog(@"Error deleting row in table: %s", errmsg);
		sqlite3_free(errmsg);
		
		NSDictionary *theProps = [[self class] propertiesWithEncodedTypes];
		
		for (NSString *prop in [theProps allKeys])
		{
			NSString *colType = [theProps valueForKey:prop];
			if ([colType hasPrefix:@"@"])
			{
				NSString *className = [prop substringWithRange:NSMakeRange(2, [prop length]-3)];
				if (isNSDictionaryType(className) || isNSArrayType(className) || isNSSetType(className))
				{
					if (cascade)
					{
						Class fkClass = objc_lookUpClass([prop UTF8String]);
						NSString *fkDeleteQuery = [NSString stringWithFormat:@"DELETE FROM %@ WHERE PK IN (SELECT FK FROM %@_%@_XREF WHERE pk = %d)",  [fkClass tableName], [self className],  [prop stringAsSQLColumnName], pk];
						// Suppress the error if there was one: it's faster than checking to see if the table exists. 
						// It may not if the property was used to store strings or another storage class but never
						// a subclass of SQLitePersistentObject
						sqlite3_exec (database, [fkDeleteQuery UTF8String], NULL, NULL, NULL);
						
					}
					
					NSString *xRefDeleteQuery = [NSString stringWithFormat:@"DELETE FROM %@_%@ WHERE parent_pk = %d", [self className], [prop stringAsSQLColumnName], pk];
					if (sqlite3_exec (database, [xRefDeleteQuery UTF8String], NULL, NULL, &errmsg) != SQLITE_OK)
						NSLog(@"Error deleting from foreign key table: %s", errmsg);
					sqlite3_free(errmsg);
				}
			}
		}
	}
}
#pragma mark -
#pragma mark NSObject Overrides 

+ (BOOL)resolveClassMethod:(SEL)theMethod
{
	NSString *methodBeingCalled = [NSString stringWithCString: sel_getName(theMethod)];
	
	if ([methodBeingCalled hasPrefix:@"findBy"])
	{
		NSRange theRange = NSMakeRange(6, [methodBeingCalled length] - 7);
		NSString *property = [[methodBeingCalled substringWithRange:theRange] stringByLowercasingFirstLetter];
		NSDictionary *properties = [self propertiesWithEncodedTypes];
		if ([[properties allKeys] containsObject:property])
		{
			SEL newMethodSelector = sel_registerName([methodBeingCalled UTF8String]);
			
			// Hardcore juju here, this is not documented anywhere in the runtime (at least no
			// anywhere easy to find for a dope like me), but if you want to add a class method
			// to a class, you have to get the metaclass object and add the clas to that. If you
			// add the method
			Class selfMetaClass = objc_getMetaClass([[self className] UTF8String]);
			return (class_addMethod(selfMetaClass, newMethodSelector, (IMP) findByMethodImp, "@@:@")) ? YES : [super resolveClassMethod:theMethod];
		}
		else
			return [super resolveClassMethod:theMethod];
	}
	return [super resolveClassMethod:theMethod];
}
-(id)init
{
	if (self=[super init])
	{
		pk = -1;
	}
	return self;
}
- (void)dealloc 
{
	[[self class] unregisterObject:self];
	[super dealloc];
}
#pragma mark -
#pragma mark Private Methods
+ (NSString *)classNameForTableName:(NSString *)theTable
{
	static NSMutableDictionary *classNamesForTables = nil;
	
	if (classNamesForTables == nil)
		classNamesForTables = [[NSMutableDictionary alloc] init];
	
	if ([[classNamesForTables allKeys] containsObject:theTable])
		return [classNamesForTables objectForKey:theTable];
	
	
	NSMutableString *ret = [NSMutableString string];
	
	BOOL lastCharacterWasUnderscore = NO;
	for (int i = 0; i < theTable.length; i++)
	{
		NSRange range = NSMakeRange(i, 1);
		NSString *oneChar = [theTable substringWithRange:range];
		if ([oneChar isEqualToString:@"_"])
			lastCharacterWasUnderscore = YES;
		else
		{
			if (lastCharacterWasUnderscore || i == 0)
				[ret appendString:[oneChar uppercaseString]];
			else
				[ret appendString:oneChar];
			
			lastCharacterWasUnderscore = NO;
		}
	}
	[classNamesForTables setObject:ret forKey:theTable];
	
	return ret;
}
+ (NSString *)tableName
{
	static NSMutableDictionary *tableNamesByClass = nil;
	
	if (tableNamesByClass == nil)
		tableNamesByClass = [[NSMutableDictionary alloc] init];
	
	if ([[tableNamesByClass allKeys] containsObject:[self className]])
		return [tableNamesByClass objectForKey:[self className]];
	
	// Note: Using a static variable to store the table name
	// will cause problems because the static variable will 
	// be shared by instances of classes and their subclasses
	// Cache in the instances, not here...
	NSMutableString *ret = [NSMutableString string];
	NSString *className = [self className];
	for (int i = 0; i < className.length; i++)
	{
		NSRange range = NSMakeRange(i, 1);
		NSString *oneChar = [className substringWithRange:range];
		if ([oneChar isEqualToString:[oneChar uppercaseString]] && i > 0)
			[ret appendFormat:@"_%@", [oneChar lowercaseString]];
		else
			[ret appendString:[oneChar lowercaseString]];
	}
	
	[tableNamesByClass setObject:ret forKey:[self className]];
	return ret;
}

+(void)tableCheck
{
	static NSMutableArray *checked = nil;
	
	if (checked == nil)
		checked = [[NSMutableArray alloc] init];
	
	if (![checked containsObject:[self className]])
	{
		[checked addObject:[self className]];
		
		// Do not use static variables to cache information in this method, as it will be
		// shared across subclasses. Do caching in instance methods.
		sqlite3 *database = [[SQLiteInstanceManager sharedManager] database];
		NSMutableString *createSQL = [NSMutableString stringWithFormat:@"CREATE TABLE IF NOT EXISTS %@ (pk INTEGER PRIMARY KEY",[self tableName]];
		
		
		for (NSString *oneProp in [[self class] propertiesWithEncodedTypes])
		{ 
			NSString *propName = [oneProp stringAsSQLColumnName];
			NSString *propType = [[[self class] propertiesWithEncodedTypes] objectForKey:oneProp];
			// Integer Types
			if ([propType isEqualToString:@"i"] || // int
				[propType isEqualToString:@"I"] || // unsigned int
				[propType isEqualToString:@"l"] || // long
				[propType isEqualToString:@"L"] || // usigned long
				[propType isEqualToString:@"q"] || // long long
				[propType isEqualToString:@"Q"] || // unsigned long long
				[propType isEqualToString:@"s"] || // short
				[propType isEqualToString:@"S"] ||  // unsigned short
				[propType isEqualToString:@"B"] )   // bool or _Bool
			{
				[createSQL appendFormat:@", %@ INTEGER", propName];		
			}	
			// Character Types
			else if ([propType isEqualToString:@"c"] ||	// char
					 [propType isEqualToString:@"C"] )  // unsigned char
			{
				[createSQL appendFormat:@", %@ TEXT", propName];
			}
			else if ([propType isEqualToString:@"f"] || // float
					 [propType isEqualToString:@"d"] )  // double
			{		 
				[createSQL appendFormat:@", %@ REAL", propName];
			}
			else if ([propType hasPrefix:@"@"] ) // Object
			{
				
				
				NSString *className = [propType substringWithRange:NSMakeRange(2, [propType length]-3)];
				
				// Collection classes have to be handled differently. Instead of adding a column, we add a child table.
				// Child tables will have a field for holding data and also a non-required foreign key field. If the
				// object stored in the collection is a subclass of SQLitePersistentObject, then it is stored as
				// a reference to the row in the table that holds the object. If it's not, then it is stored
				// in the field using the SQLitePersistence protocol methods. If it's not a subclass of 
				// SQLitePersistentObject and doesn't conform to NSCoding then the object won't get persisted.
				if (isNSArrayType(className))
				{
					NSString *xRefQuery = [NSString stringWithFormat:@"CREATE TABLE IF NOT EXISTS %@_%@ (parent_pk, array_index INTEGER, fk INTEGER, fk_table_name TEXT, object_data TEXT, object_class BLOB, PRIMARY KEY (parent_pk, array_index))", [self tableName], [propName stringAsSQLColumnName]];
					char *errmsg = NULL;
					if (sqlite3_exec (database, [xRefQuery UTF8String], NULL, NULL, &errmsg) != SQLITE_OK)		
						NSLog(@"Error Message: %s", errmsg);
					
				}
				else if (isNSDictionaryType(className))
				{
					NSString *xRefQuery = [NSString stringWithFormat:@"CREATE TABLE IF NOT EXISTS %@_%@ (parent_pk integer, dictionary_key TEXT, fk INTEGER, fk_table_name TEXT, object_data BLOB, object_class TEXT, PRIMARY KEY (parent_pk, dictionary_key))", [self tableName], [propName stringAsSQLColumnName]];
					char *errmsg = NULL;
					if (sqlite3_exec (database, [xRefQuery UTF8String], NULL, NULL, &errmsg) != SQLITE_OK)		
						NSLog(@"Error Message: %s", errmsg);
					
				}
				else if (isNSSetType(className))
				{
					NSString *xRefQuery = [NSString stringWithFormat:@"CREATE TABLE IF NOT EXISTS %@_%@ (parent_pk INTEGER, fk INTEGER, fk_table_name TEXT, object_data BLOB, object_class TEXT)", [self tableName], [propName stringAsSQLColumnName]];
					char *errmsg = NULL;
					if (sqlite3_exec (database, [xRefQuery UTF8String], NULL, NULL, &errmsg) != SQLITE_OK)		
						NSLog(@"Error Message: %s", errmsg);
				}
				else
				{
					Class propClass = objc_lookUpClass([className UTF8String]);
					
					if ([propClass isSubclassOfClass:[SQLitePersistentObject class]])
					{
						// Store persistent objects as quasi foreign-key reference. We don't use
						// datbase's referential integrity tools, but rather use the memory map
						// key to store the table and fk in a single text field
						[createSQL appendFormat:@", %@ TEXT", propName];
					}
					else if ([propClass canBeStoredInSQLite])
					{
						[createSQL appendFormat:@", %@ %@", propName, [propClass columnTypeForObjectStorage]];
					}
				}
				
			}
			
			
		}	 
		[createSQL appendString:@")"];
		
		char *errmsg = NULL;
		if (sqlite3_exec (database, [createSQL UTF8String], NULL, NULL, &errmsg) != SQLITE_OK)		
			NSLog(@"Error Message: %s", errmsg);
		
		NSArray *theIndices = [self indices];
		if (theIndices != nil)
		{
			if ([theIndices count] > 0)
			{
				for (NSArray *oneIndex in theIndices)
				{
					NSMutableString *indexName = [NSMutableString stringWithString:[self tableName]];
					NSMutableString *fieldCondition = [NSMutableString string];
					BOOL first = YES;
					for (NSString *oneField in oneIndex)
					{
						[indexName appendFormat:@"_%@", [oneField stringAsSQLColumnName]];
						
						if (first) 
							first = NO;
						else
							[fieldCondition appendString:@", "];
						[fieldCondition appendString:[oneField stringAsSQLColumnName]];
					}
					NSString *indexQuery = [NSString stringWithFormat:@"create index if not exists %@ on %@ (%@)", indexName, [self tableName], fieldCondition];
					errmsg = NULL;
					if (sqlite3_exec (database, [indexQuery UTF8String], NULL, NULL, &errmsg) != SQLITE_OK)
						NSLog(@"Error creating indices on %@: %s", [self tableName], errmsg);
				}
				
				
				
			}
		}
	}
}
- (void)setPk:(int)newPk
{
	pk = newPk;
}
#pragma mark -
#pragma mark Memory Map Methods
- (NSString *)memoryMapKey
{
	return [NSString stringWithFormat:@"%@-%d", [self className], [self pk]];
}
+ (void)registerObjectInMemory:(SQLitePersistentObject *)theObject
{
	if (objectMap == nil)
		objectMap = [[NSMutableDictionary alloc] init];
	
	[objectMap setObject:theObject forKey:[theObject memoryMapKey]];
	
}
+ (void)unregisterObject:(SQLitePersistentObject *)theObject
{
	if (objectMap == nil)
		objectMap = [[NSMutableDictionary alloc] init];
	
	// We have to make sure we're not removing objects from memory map when deleting partially created ones...
	SQLitePersistentObject *compare = [objectMap objectForKey:[theObject memoryMapKey]];
	if (compare == theObject)
		[objectMap removeObjectForKey:[theObject memoryMapKey]]; 
}
@end
