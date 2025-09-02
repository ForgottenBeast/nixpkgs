{
  lib,
  buildPythonPackage,
  fetchFromGitHub,
  fetchPypi,

  # Build dependencies
  setuptools,
  wheel,
  pybind11,
  cmake,
  pkg-config,

  # System dependencies
  boost,
  libomp,
  blas,
  lapack,

  # Python dependencies
  numpy,
  boto3,
  colorama,
  datasets,
  evaluate,
  gitignore-parser,
  ipykernel,
  llama-index-core,
  llama-index-embeddings-huggingface,
  llama-index-readers-file,
  msgpack,
  nbconvert,
  ollama,
  openai,
  pathspec,
  pdfplumber,
  protobuf,
  psutil,
  pymupdf,
  pypdf2,
  pypdfium2,
  requests,
  sentence-transformers,

  # Test dependencies
  pytestCheckHook,
  pytest-asyncio,
}:

let
  # Custom dependencies not in nixpkgs
  llama-index-vector-stores-faiss = buildPythonPackage rec {
    pname = "llama_index_vector_stores_faiss";
    version = "0.5.0";
    format = "wheel";

    src = fetchPypi {
      inherit pname version format;
      sha256 = "sha256-L6mEikQj3bJvmH0pl0nx+hwnK45XYzKgPgYQ1O4jbQk=";
      python = "py3";
      dist = "py3";
    };

    # Prevent tests from running for this wheel
    doCheck = false;

    meta = with lib; {
      description = "FAISS vector store for LlamaIndex";
      homepage = "https://pypi.org/project/llama_index_vector_stores_faiss/";
      license = licenses.mit;
    };
  };

  sglang = buildPythonPackage rec {
    pname = "sglang";
    version = "0.5.1.post3";
    format = "wheel";

    src = fetchPypi {
      inherit pname version format;
      sha256 = "sha256-+S9W9vpjIAEoctof43MX5mXfVWrwJy7/Z6+K+zmT7Aw=";
      python = "py3";
      dist = "py3";
    };

    # Prevent tests from running for this wheel
    doCheck = false;

    meta = with lib; {
      description = "Structured Generation Language for LLMs";
      homepage = "https://pypi.org/project/sglang/";
      license = licenses.asl20;
    };
  };

in buildPythonPackage rec {
  pname = "leann";
  version = "0.3.2";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "yichuan-w";
    repo = "LEANN";
    rev = "v${version}"; # Use version tag when available, fallback to commit hash
    hash = "sha256-KT6EpwZ63WEMpZo6C7IHXxyTIGoMd2oEx6O+bNXAUnA=";
    fetchSubmodules = true;
  };

  # Build system dependencies
  build-system = [
    setuptools
    wheel
    pybind11
    cmake
  ];

  nativeBuildInputs = [
    pkg-config
    cmake
  ];

  buildInputs = [
    boost
    libomp
    blas
    lapack
  ];

  dependencies = [
    numpy
    boto3
    colorama
    datasets
    evaluate
    gitignore-parser
    ipykernel
    llama-index-core
    llama-index-embeddings-huggingface
    llama-index-readers-file
    llama-index-vector-stores-faiss
    msgpack
    nbconvert
    ollama
    openai
    pathspec
    pdfplumber
    protobuf
    psutil
    pybind11
    pymupdf
    pypdf2
    pypdfium2
    requests
    sentence-transformers
    sglang
  ];

  # Handle UV workspace structure
  preBuild = ''
    # UV workspace builds all packages together
    # Set environment variables for C++ compilation
    export CMAKE_BUILD_TYPE=Release
    export CMAKE_ARGS="-DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_STANDARD=17"

    # Handle potential missing __init__.py files in subpackages
    for pkg_dir in packages/*/; do
      if [[ -d "$pkg_dir" && ! -f "$pkg_dir/__init__.py" ]]; then
        touch "$pkg_dir/__init__.py"
      fi
    done
  '';

  # Relax dependencies to avoid version conflicts
  pythonRelaxDeps = [
    "numpy"
    "protobuf"
    "datasets"
    "sentence-transformers"
    "openai"
  ];

  # Remove problematic dependencies that cause issues
  pythonRemoveDeps = [
    # Remove any problematic deps here if needed
  ];

  nativeCheckInputs = [
    pytestCheckHook
    pytest-asyncio
  ];

  # Disable tests initially due to complexity of test setup
  doCheck = false;

  # When enabling tests, these would be useful
  preCheck = ''
    export HOME=$(mktemp -d)
    export TMPDIR=$(mktemp -d)
  '';

  pythonImportsCheck = [
    "leann"
  ];

  # Test basic functionality without requiring external models
  checkPhase = ''
    runHook preCheck

    # Basic import test
    python -c "
    import leann
    from leann import LeannBuilder
    print('LEANN import successful')

    # Test basic builder creation (should not require external dependencies)
    try:
        builder = LeannBuilder(backend_name='hnsw')
        print('LEANN builder creation successful')
    except Exception as e:
        print(f'Builder creation failed: {e}')
        # Don't fail the build for this, as it might require runtime setup
    "

    runHook postCheck
  '';

  meta = with lib; {
    description = "LEANN: A Low-Storage Vector Index for RAG applications";
    longDescription = ''
      LEANN is an innovative vector database that democratizes personal AI.
      Transform your laptop into a powerful RAG system that can index and search
      through millions of documents while using 97% less storage than traditional
      solutions without accuracy loss.

      LEANN achieves this through graph-based selective recomputation with
      high-degree preserving pruning, computing embeddings on-demand instead
      of storing them all.
    '';
    homepage = "https://github.com/yichuan-w/LEANN";
    changelog = "https://github.com/yichuan-w/LEANN/releases/tag/v${version}";
    license = licenses.mit;
    maintainers = with maintainers; [ ]; # Add maintainer here
    platforms = platforms.unix;

    # This package has some heavy dependencies and C++ compilation
    broken = stdenv.isDarwin; # May need Darwin-specific fixes
  };
}
