// No signing, transactions or explorer API keys. RPC_URL is optional and never printed.
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync,mkdirSync} from 'node:fs';
import solc from 'solc';
import {Interface,keccak256,getCreateAddress} from 'ethers';
const requested=process.argv.includes('--chain')?Number(process.argv[process.argv.indexOf('--chain')+1]):null;
assert(!requested||[1,4663].includes(requested),'Choose chain 1 or 4663');
const chains=requested?[requested]:[1,4663];let rpcId=0;
async function rpc(method,params){
 const response=await fetch(process.env.RPC_URL,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({jsonrpc:'2.0',id:++rpcId,method,params}),signal:AbortSignal.timeout(30000)});
 const json=await response.json();assert(response.ok&&!json.error,'RPC call failed: '+method);return json.result;
}
try{
 for(const chain of chains){
  const folder='deployments/'+chain,manifest=JSON.parse(readFileSync(folder+'/manifest.json'));
  assert(solc.version().startsWith(manifest.compiler),'Wrong compiler');
  if(process.env.RPC_URL){assert(requested,'With RPC_URL choose one --chain');assert.equal(Number(BigInt(await rpc('eth_chainId',[]))),chain,'Wrong RPC chain');}
  for(const contract of manifest.contracts){
   const input=JSON.parse(readFileSync(folder+'/'+contract.name+'.input.json'));
   // Read the reviewable files, asserting the publication matches the original standard input.
   for(const [path,source] of Object.entries(input.sources))if(path.startsWith('src/')){
    const local=readFileSync(path,'utf8');assert.equal(local,source.content,'Source differs: '+path);source.content=local;
   }
   const output=JSON.parse(solc.compile(JSON.stringify(input)));
   assert(!(output.errors||[]).some(e=>e.severity==='error'),'Compilation failed');
   const artifact=output.contracts['src/'+contract.name+'.sol'][contract.name];
   const args=new Interface(artifact.abi).encodeDeploy(contract.constructorArgs).slice(2);
   assert.equal(args,readFileSync(folder+'/'+contract.name+'.arguments.txt','utf8').trim(),'Constructor mismatch');
   const init='0x'+artifact.evm.bytecode.object+args;
   assert.equal(keccak256(init),contract.dataHash,'Creation bytecode hash differs');
   assert.equal(getCreateAddress({from:manifest.deployer,nonce:contract.nonce}).toLowerCase(),contract.address.toLowerCase(),'Deployment address differs');
   const report={chainId:chain,name:contract.name,address:contract.address,creationCodeHash:keccak256(init),expectedRuntimeCodeHash:contract.runtimeCodeHash,liveChecked:false};
   if(process.env.RPC_URL){
    const tx=await rpc('eth_getTransactionByHash',[contract.transactionHash]);assert(tx&&tx.to===null&&tx.blockNumber,'Missing mined creation');
    assert.equal(tx.input.toLowerCase(),init.toLowerCase(),'Mined constructor input differs');assert.equal(tx.from.toLowerCase(),manifest.deployer.toLowerCase());assert.equal(Number(BigInt(tx.nonce)),contract.nonce);
    const receipt=await rpc('eth_getTransactionReceipt',[contract.transactionHash]);assert.equal(receipt.status,'0x1');assert.equal(receipt.contractAddress.toLowerCase(),contract.address.toLowerCase());
    const code=await rpc('eth_getCode',[contract.address,'latest']);assert.equal(keccak256(code),contract.runtimeCodeHash,'Full deployed runtime hash differs');
    let template=artifact.evm.deployedBytecode.object.toLowerCase(),actual=code.slice(2).toLowerCase();assert.equal(template.length,actual.length);
    // Recent Solidity exposes the library guard as a named immutable reference.
    const guard=artifact.evm.deployedBytecode.immutableReferences?.library_deploy_address;
    if(guard)for(const {start,length} of guard)assert.equal(actual.slice(start*2,(start+length)*2),contract.address.slice(2).toLowerCase().padStart(length*2,'0'),'Library guard address differs');
    // Immutable values are initialized by the exact constructor verified above. Only the
    // compiler-listed immutable spans are normalized for the runtime template comparison.
    for(const refs of Object.values(artifact.evm.deployedBytecode.immutableReferences||{}))for(const {start,length} of refs){
     template=template.slice(0,start*2)+'0'.repeat(length*2)+template.slice((start+length)*2);
     actual=actual.slice(0,start*2)+'0'.repeat(length*2)+actual.slice((start+length)*2);
    }
    assert.equal(actual,template,'Runtime template differs');report.liveChecked=true;report.runtimeCodeHash=keccak256(code);
   }
   mkdirSync('build/'+chain,{recursive:true});writeFileSync('build/'+chain+'/'+contract.name+'.json',JSON.stringify({report,abi:artifact.abi},null,2)+'\n');
   console.log(chain+' '+contract.name+': creation hash MATCH'+(report.liveChecked?', mined constructor + full runtime hash + runtime template MATCH':''));
  }
 }
}catch(error){console.error(error instanceof assert.AssertionError?error.message:'Verification failed (RPC details suppressed).');process.exitCode=1;}
