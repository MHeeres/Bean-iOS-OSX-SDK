//
//  BeanLocator.m
//  Bean OSX Library
//
//  Created by Raymond Kampmeier on 2/18/14.
//  Copyright (c) 2014 Punch Through Design. All rights reserved.
//

#import "BeanManager.h"
#import "BEAN_Helper.h"
#import "GattSerialProfile.h"
#import "Bean+Protected.h"

//@interface BeanRecord : NSObject
//@property (strong, nonatomic) NSDate       * last_seen;
//@property (strong, nonatomic) CBPeripheral * peripheral;
//@property (strong, nonatomic) NSNumber     * rssi;
//@property (strong, nonatomic) NSDictionary * advertisementData;
//@property (strong, nonatomic) Bean         * bean;
//@property (nonatomic) BeanRecordConnectionState        state;
//@end
//@implementation BeanRecord
//@end


@interface BeanManager () <CBCentralManagerDelegate, BeanDelegate>
@end

@implementation BeanManager{
    CBCentralManager* cbcentralmanager;
    
    NSMutableDictionary* beanRecords; //Uses NSUUID as key
}

#pragma mark - Public methods

-(id)init{
    self = [super init];
    if (self) {
        beanRecords = [[NSMutableDictionary alloc] init];
        cbcentralmanager = [[CBCentralManager alloc] initWithDelegate:self queue:nil];
    }
    return self;
}

-(id)initWithDelegate:(id<BeanManagerDelegate>)delegate{
    self.delegate = delegate;
    return [self init];
}

-(BeanManagerState)state{
    return cbcentralmanager?(BeanManagerState)cbcentralmanager.state:0;
}

-(void)startScanningForBeans_error:(NSError**)error{
    // Bluetooth must be ON
    if (cbcentralmanager.state != CBCentralManagerStatePoweredOn){
        if (error) *error = [BEAN_Helper basicError:@"Bluetooth is not on" domain:NSStringFromClass([self class]) code:100];
        return;
    }
    
    // Scan for peripherals
    NSLog(@"Started scanning...");
    
    //Clear array of previously discovered peripherals.
    [beanRecords removeAllObjects];
    
    // Define array of app service UUID
    NSArray * services = [NSArray arrayWithObjects:[CBUUID UUIDWithString:GLOBAL_SERIAL_PASS_SERVICE_UUID], nil];
    
    //Begin scanning
    [cbcentralmanager scanForPeripheralsWithServices:services options:0];
}

-(void)stopScanningForBeans_error:(NSError**)error{
    // Bluetooth must be ON
    if (cbcentralmanager.state != CBCentralManagerStatePoweredOn)
    {
        if (error) *error = [BEAN_Helper basicError:@"Bluetooth is not on" domain:@"API:BLE Connection" code:100];
        return;
    }
    
    [cbcentralmanager stopScan];
    
    NSLog(@"Stopped scanning.");
}

-(void)connectToBeanWithUUID:(NSUUID*)uuid error:(NSError**)error{
    //Find BeanRecord that corresponds to this UUID
    Bean* bean = [beanRecords objectForKey:uuid];
    //If there is no such peripheral, return error
    if(!bean){
        if(error) *error = [BEAN_Helper basicError:@"Attemp to connect to Bean failed. No peripheral discovered with the corresponding UUID." domain:NSStringFromClass([self class]) code:100];
        return;
    }
    //Check if the device is already connected
    else if(bean.state == BeanState_ConnectedAndValidated){
        if(error) *error = [BEAN_Helper basicError:@"Attemp to connect to Bean failed. A device with this UUID is already connected" domain:NSStringFromClass([self class]) code:100];
        return;
    }
    //Check if the device is already in the middle of an attempted connected
    else if(bean.state == BeanState_AttemptingConnection || bean.state == BeanState_AttemptingValidation){
        if(error) *error = [BEAN_Helper basicError:@"Attemp to connect to Bean failed. A device with this UUID is in the process of being connected to." domain:NSStringFromClass([self class]) code:100];
        return;
    }else if(bean.state != BeanState_Discovered){
        if(error) *error = [BEAN_Helper basicError:@"Attemp to connect to Bean failed. The device's current state is not eligible for a connection attempt." domain:NSStringFromClass([self class]) code:100];
        return;
    }
    //Mark this BeanRecord as is in the middle of a connection attempt
    [bean setState:BeanState_AttemptingConnection];
    //Attempt to connect to the corresponding CBPeripheral
    [cbcentralmanager connectPeripheral:bean.peripheral options:nil];
}

-(void)disconnectBeanWithUUID:(NSUUID*)uuid error:(NSError**)error{
    //Find BeanPeripheral that corresponds to this UUID
    Bean* bean = [beanRecords objectForKey:uuid];
    //Check if the device isn't currently connected
    if(!bean || bean.state != BeanState_ConnectedAndValidated){
        if(error) *error = [BEAN_Helper basicError:@"Failed attemp to disconnect Bean. No device with this UUID is currently connected" domain:NSStringFromClass([self class]) code:100];
        return;
    }
    //Mark this BeanRecord as is in the middle of a disconnection attempt
    [bean setState:BeanState_AttemptingDisconnection];
    //Attempt to disconnect from the corresponding CBPeripheral
    [cbcentralmanager cancelPeripheralConnection:bean.peripheral];
}

#pragma mark - Protected methods
-(void)bean:(Bean*)device hasBeenValidated_error:(NSError*)error{
    NSError* localError;
    //Find BeanRecord that corresponds to this UUID
    Bean* bean = [beanRecords objectForKey:[device identifier]];
    //If there is no such peripheral, return error
    if(!bean){
        localError = [BEAN_Helper basicError:@"Attemp to connect to Bean failed. No peripheral discovered with the corresponding UUID." domain:NSStringFromClass([self class]) code:100];
    }
    else if (error){
        localError = error;
        bean.state = BeanState_Discovered; // Reset bean state to the default, ready to connect
    }else{
        bean.state = BeanState_ConnectedAndValidated;
    }
    //Notify Delegate
    if (self.delegate && [self.delegate respondsToSelector:@selector(BeanManager:didConnectToBean:error:)]){
        [self.delegate BeanManager:self didConnectToBean:device error:error];
    }
}


#pragma mark - Private methods


#pragma mark - CBCentralManagerDelegate

- (void)centralManagerDidUpdateState:(CBCentralManager *)central{
    //Notify delegate of state
    if (self.delegate && [self.delegate respondsToSelector:@selector(beanManagerDidUpdateState:)]){
        [self.delegate beanManagerDidUpdateState:self];
    }
    switch (central.state) {
        case CBCentralManagerStatePoweredOn:
            NSLog(@"%@: Bluetooth ON", self.class.description);
            break;
            
        default:
            NSLog(@"%@: Bluetooth state error: %ld", self.class.description, central.state);
            break;
    }
}

-(void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)peripheral advertisementData:(NSDictionary *)advertisementData RSSI:(NSNumber *)RSSI{
    Bean * bean;
    //This Bean is already discovered and perhaps connected to
    if ((bean = [beanRecords objectForKey:peripheral.identifier])) {
        bean.RSSI = RSSI;
        bean.lastDiscovered = [NSDate date];
        bean.advertisementData = advertisementData;
    }
    else { // A new undiscovered Bean
        NSLog(@"centralManager:didDiscoverPeripheral %@", peripheral);
        bean = [[Bean alloc] initWithPeripheral:peripheral beanManager:self];
        bean.RSSI = RSSI;
        bean.lastDiscovered = [NSDate date];
        bean.advertisementData = advertisementData;
        bean.state = BeanState_Discovered;
        
        [beanRecords setObject:bean forKey:peripheral.identifier];
    }
    //Inform the delegate that we located a Bean
    if (self.delegate && [self.delegate respondsToSelector:@selector(BeanManager:didDisconnectBean:error:)]){
        [self.delegate BeanManager:self didDiscoverBean:bean error:nil];
    }
}

-(void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral{
    //Find BeanRecord that corresponds to this UUID
    Bean* bean = [beanRecords objectForKey:[peripheral identifier]];
    //If there is no such peripheral, return
    if(!bean)return;
    //Mark Bean peripheral as no longer being in a connection attempt
    bean.state = BeanState_AttemptingValidation;
    //Wait for Bean validation before responding to delegate
    [bean interrogateAndValidate];
}

- (void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error{
    //Find BeanRecord that corresponds to this UUID
    Bean* bean = [beanRecords objectForKey:[peripheral identifier]];
    //If there is no such peripheral, return
    if(!bean)return;
    //Mark Bean peripheral as no longer being in a connection attempt
    bean.state = BeanState_Discovered;
    //Make sure that there is an error to pass along
    if(!error)return;
    //Notify delegate of failure
    if (self.delegate && [self.delegate respondsToSelector:@selector(BeanManager:didConnectToBean:error:)]){
        [self.delegate BeanManager:self didConnectToBean:nil error:error];
    }
}

- (void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error{
    //Find BeanRecord that corresponds to this UUID
    Bean* bean = [beanRecords objectForKey:[peripheral identifier]];
    if(bean){
        //Mark Bean peripheral as no longer being connected
        bean.state = BeanState_Discovered;
    }else if (!error){ //No Record of this Bean and there is no error
        return;
    }
    
    if(!bean) return; //This may not be the best way to handle this case
    //Alert the delegate of the disconnect
    if (self.delegate && [self.delegate respondsToSelector:@selector(BeanManager:didDisconnectBean:error:)]){
        [self.delegate BeanManager:self didDisconnectBean:bean error:error];
    }
}


@end