configuration TransportObjectC {
    provides interface TransportObject;
}

implementation {
    components TransportObjectP;
    TransportObject = TransportObjectP;
	
	components TransportC as Transport;
	TransportObjectP.Transport -> Transport;
	
	//uses interface Random;
	//uses interface Transport;
	//uses interface Hashmap<uint8_t> as Connections;
	//uses interface Timer<TMilli> as myTimer;
	//uses interface SimpleSend as Sender;
	
    components new SimpleSendC(AM_PACK);
    TransportObjectP.Sender -> SimpleSendC;

    components new TimerMilliC() as myTimer;
    TransportObjectP.myTimer -> myTimer;

	components ChatC as Chat;
	TransportObjectP.Chat -> Chat;
	
    components RandomC as Random;
    TransportObjectP.Random -> Random;

    components new HashmapC(uint8_t, 20) as Connections;
    TransportObjectP.Connections -> Connections;
}